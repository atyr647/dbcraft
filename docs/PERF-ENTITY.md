# Entity performance: awake mobs (MOB-PERF)

Goal: an awake walking mob should cost less than vanilla's ~22 µs per tick, with entities still readable rows and the logic in SQL,
and no change to the physics of recorded vanilla trajectories (deviation 0 in the existing tests 510/530).

All numbers are CPU time of the backend (getrusage via `public.cpu_ms()`), interleaved A/B (`tests/bench/entity/ab.sh`), medians,
one core, 60 ticks, mobs staggered over their 60-tick phases. `proto` is the original entity tick (`dbcraft.entity_impl=proto`,
`dbcraft.entity_lanes=off`); `lanes` is the new one. The machine was shared, so only the interleaved comparisons mean anything.

## Where the 150 µs went

Per awake walking mob and tick in the prototype (2,000 mobs, 1 viewer: 72–80 ms per tick = 36–40 µs per mob *on average*, 150 µs
for a mob that is in a tracker step):

| step | ms/tick (2,000 mobs) | what it did |
|---|---|---|
| physics | 73–89 | every awake mob: row update (wide row, HOT), gravity, collision sweep against the block table, every tick |
| tracker | 38–50 | delta against the last sent state, packet built from ~10 small builders, one `play_out` row per viewer |
| AI | 13–15 | goal selection |

The cost is dominated by doing, every tick, per-row work whose result is a straight line: a mob on flat ground walks at
constant velocity for a whole goal (up to 80 ticks), so its position at any tick is a closed-form function.

## Levers

### 1. Lanes (dead reckoning) — the big one
`sql/541_entity_lanes.sql`. A mob that starts a goal on a uniform floor gets a *lane*: the lane is valid for the whole goal if
every column its footprint covers has its highest solid block directly under the feet (checked once per goal against
`mc.entity_floor`, a per-chunk summary: min/max top plus a 256-entry per-column `tops` array, built on first touch, at most 8
builds per tick, invalidated by block changes). The lane ends at the goal's end or one tick before the centre leaves its chunk,
so cx/cz and thus the set of viewers stay exact. While in a lane the entity row is **not written**; its position is `x + gx·(t − phys_tick)`
(`mc.entity_live` gives the exact position of every entity, lane or not). The tracker's delta base lives in a small table `mc.entity_lane`
(FK cascade) and the lane tracker steps only the mobs that are due in their update interval. Anything the lane cannot represent
exactly (position sync, a delta that does not fit a short, block changes under the lane, a wake-up) ends the lane and goes through the
generic path. Result: 1 write per goal instead of 1 per tick, physics skipped, tracker O(due mobs).

### 2. Tight mob packet builder
`sql/542_entity_tracker_fast.sql`: `mc.epkt_mob_move`, byte-identical to the chain of small builders (tests compare them),
falling back to the generic builders for ids/ticks/pid outside the fast range.

### 3. Smaller changes
* `entity_awake_nolane_idx` (physics reads only entities outside lanes), `entity_lane` as a separate narrow table, array-based
  updates, primary-key probes (`offset 0`) instead of the planner's scans.
* viewers_refresh: `NOT IN` (hashed) instead of `NOT EXISTS` — the function-level `enable_hashjoin = off` turned the anti-join into
  500 × 500 comparisons (8.3 → 0.9 ms at 500 players).
* `mc.block_class_refresh()` (`sql/540`): `block_class` was empty on a fresh database, which made entity tests fail; loader calls it.
* `entity_lane` autovacuum options: the table churns; a quiet world otherwise scans ten megabytes of dead pages each tick (found when
  5,000 resting items cost 26 ms instead of 2 ms).

## Results (entity tick, ms per tick, CPU)

| scenario | proto | lanes | per mob (lanes) |
|---|---|---|---|
| 2,000 awake walking mobs, 1 player | 72–80 | **28–32** | 14–16 µs |
| 10,000 awake walking mobs, 1 player (sharing the machine with a test run) | — | 110 | 11 µs |
| 500 players + 2,000 awake mobs (area 790) | 83 | **52.7** | 26 µs |
| 5,000 resting items, 1 player | 1.5 | 2.2 | resting win kept, +0.6 ms for the empty lane scans |

Versus vanilla's ~22 µs/mob: **beaten for the single-viewer case (11–16 µs)**, not for the 500-player fan-out case.
Targets: 2,000 mobs ≤ 40 ms ✔ (28–32 ms); < 25 ms with pipeline ✘ (pipeline not built, see below); 500 players + 2,000 mobs
≤ 50 ms ✘ (52.7 ms for the entity part alone); 10,000 awake mobs ✘ (110 ms per tick on a shared machine: over the 50 ms tick, but
~11 µs per mob).

Remaining cost in the 500-player case (ms CPU per tick): AI 9.2, lane_try + step 19.5, tracker 5.3, physics 3.0, flush 2.1,
pickup 1.7, viewers 0.9. The lane step is bounded by fan-out: each mob is seen by ~19 viewers, so ~2,000 × (1/due) × 19 packets
per tick must be written. That is output volume the vanilla server pays too (in its network threads, not in MSPT), so the
comparison there is not like for like.

## What did not work / pitfalls
* Chunk-level floor check only (min == max): too few mobs qualified on bumpy chunks. Per-column `tops` fixed it.
* Planner traps: stale statistics on partial indexes, `generate_series` estimated at 1,000 rows (use `values` expansions),
  nested loops forced by `enable_hashjoin = off`, row-at-a-time updates. Fixes: arrays, `offset 0`, bounded builds.
* First-touch floor builds (~1.7 ms/chunk) spiked ticks: bounded to 8 per call, prebuilt in the benchmark.
* A lane that copied the sent base before the tracker ran drifted (test E): the post-physics `lane_try` runs after the tracker.
* Running tests against the benchmark database polluted it with blocks: never do that.

## Not done
* Real vanilla goal cadences (javap), vanilla all-walking MSPT data point: the comparison number remains vanilla's ~22 µs/mob
  from the earlier measurement, with its idle-cow caveat; no pathfinding or mob-to-mob collision in the prototype.
* Pipeline (entity tick on a second connection): not built or measured; the entity tick reads and writes disjoint tables from the
  player tick except `play_out`, so it is the next lever, estimated at hiding up to the whole 28 ms behind the player tick.

## Reproduce
```
DBCRAFT_PGDATA=/tmp/dbcraft-pg-mob DBCRAFT_PGPORT=54611 tests/bench/entity/setup_db.sh
tests/bench/entity/ab.sh 2 "proto|-c dbcraft.entity_impl=proto -c dbcraft.entity_lanes=off" "lanes|-c dbcraft.entity_lanes=on" \
   -- -v players=1 -v rest=0 -v mobs=2000 -v falling=0 -v area=100 -v ticks=60
psql -v ticks=40 -f tests/bench/entity/phases.sql      # per-step CPU, after a bench_tick.sql run
```
Correctness: `tests/sql/541_entity_lanes.sql` (27 checks: lanes on vs off positions to 1e-9, viewer reconstruction from packets equals
the sent state exactly, packet builder byte-identical).
