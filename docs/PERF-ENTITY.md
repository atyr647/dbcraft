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

## Part 2 (MULTICORE worker): fan-out per cell, three plan traps, the vanilla parameters

Measured with alternating A/B inside ONE session (`tests/bench/multicore/ab_tick.sql`: the definitions are swapped with `CREATE OR REPLACE` between ticks, so population, caches and machine load
are shared; plain `bench_tick.sql` runs of this machine differ by 40 % from run to run with the table state). `sql/551_entity_fanout.sql`:

| scenario (entity tick, CPU ms per tick, same session) | before | after |
|---|---|---|
| 500 players + 2,000 mobs, area 790 (about 1,100 awake) | 43.5 (p50 40.1) | **34.4** (p50 31.5) |
| 500 players crowded in 3x3 chunks + about 1,000 awake mobs, static players | 117.7 | **25.4** |

What changed (each found with `auto_explain` on a whole tick, `tests/bench/multicore/autoexplain_tick.sql`):
* **Lane step, per-cell blob fan-out**: the packets of the due mobs of one (chunk cell, tracking range) are concatenated once into a blob and every viewer of the cell gets the blob (the idea of
  `mc.fanout_moves` of sql/430 for players); with clustered mobs this cuts the (mob, viewer) rows by the number of mobs per cell. The second probe (tracking range against the viewer's cell) is skipped when the range
  is at least the view distance (every viewer of the cell is in range by construction). The blobs of one viewer are concatenated unordered (no sort of 7,000 rows): the set of packets per viewer is unchanged,
  their order across entities is not specified (tests/sql/551 compares the multiset byte for byte against an oracle computed from the rows: closed-form position, delta base, Chebyshev range).
* **Plan trap 1**, lane step: with statistics from before the lanes existed the planner estimated one row and scanned the whole entity table once per due id (5 ms of 13): one primary-key probe per id (`offset 0`).
* **Plan trap 2**, tracker for movers that change chunk: `mc.pkt_remove_entities` was evaluated per (entity, viewer) pair inside an anti-join (1,500 pairs x 27 us = 40 ms with 500 crowded viewers and 3 border
  crossers); now once per entity.
* **Plan trap 3**, despawn (every 20th tick): `NOT EXISTS` in an OR condition becomes a hashed sub-plan that reads the whole interest relation (220,000 rows at 500 players, 36 to 77 ms); one probe per mob (`offset 0`).
* Byte identity: `mc.epkt_mob_move` and the appearance/removal packets are untouched; tests 510, 530, 541 pass unchanged, tests/sql/551 checks the lane-step packets, the border-crossing tracker packets
  (remove / appear / move bytes) and both range paths against independent oracles, including the `ticks` field of the first packet after a gap (`3 - last_tick`).

**Targets**: 500 players + 2,000 awake mobs <= 25 ms on one connection: **not met** (34.4 ms in the walking-area case; 25.4 ms in the crowded case). 10,000 awake mobs with 100 players inside 50 ms:
**not met** (89 ms per tick, about 9 us per mob: 60 ms in AI / lanes / viewers, 19 ms in the sweep of the mobs standing or starting a goal, 9 ms tracker; the lane step alone spends 11 ms on the 1,100 due
primary-key probes of a wide row table and 26 ms on 4,100 (mob, viewer) pairs, both cache-miss bound at this size). Mob packets are byte-identical to the existing tests.

**Vanilla parameters, re-read from the 26.3 bytecode** (`javap -c`, `EntityTypes.<clinit>`, `EntityType$Builder`, `ChunkMap$TrackedEntity.updatePlayer`; `mc.entity_type_param` carried "from memory" before):
`clientTrackingRange` cow 10, zombie 8, item 6, armor stand / chicken / pig / sheep 10, creeper / skeleton 8, player 32 (chunks); `updateInterval` item 20, player 2 (+ `dontTrackDeltas`), everything else the Builder
default 3 (the Builder's default range is 5). The values in the table are right; tests/sql/551 pins them.
**Difference not changed here**: vanilla's visibility test is a CIRCLE in blocks on exact positions, `dx^2 + dz^2 <= min(range * 16, viewDistance * 16)^2` (plus `isChunkTracked`), re-evaluated for every tracked
entity as players and entities move; this prototype uses the chunk-cell relation (Chebyshev distance of chunks, constant while a lane lasts). The cell square contains the circle, so the prototype sends to up to
(2r+1)^2 / (pi r^2) = 1.4x as many viewers at r = 10 as vanilla would (441 vs 314 chunk areas); an exact test would cut the pairs by about 30 % but needs per-tick distances instead of a cell lookup.
**Not done**: the byte/cadence comparison against recorded vanilla MOB traffic (RCON `/summon` + probe, `tools/capture_vanilla.py`): not repeated; the existing tests compare the item traffic of a capture.

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
* Pipeline (entity tick on a second connection): built and measured in docs/PERF-MULTICORE.md (`dbcraft.entity-mode = split`, sql/550).

## Reproduce
```
DBCRAFT_PGDATA=/tmp/dbcraft-pg-mob DBCRAFT_PGPORT=54611 tests/bench/entity/setup_db.sh
tests/bench/entity/ab.sh 2 "proto|-c dbcraft.entity_impl=proto -c dbcraft.entity_lanes=off" "lanes|-c dbcraft.entity_lanes=on" \
   -- -v players=1 -v rest=0 -v mobs=2000 -v falling=0 -v area=100 -v ticks=60
psql -v ticks=40 -f tests/bench/entity/phases.sql      # per-step CPU, after a bench_tick.sql run
```
Correctness: `tests/sql/541_entity_lanes.sql` (27 checks: lanes on vs off positions to 1e-9, viewer reconstruction from packets equals
the sent state exactly, packet builder byte-identical).
