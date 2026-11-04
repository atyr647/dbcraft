# Entity simulation as set-based SQL (prototype)

Status: prototype, opt-in (nothing calls `mc.entity_tick` unless the server loop is told to), new files only:
`sql/500..530_entity_*.sql`, `tests/sql/510_*`, `tests/sql/530_*`, `tests/bench/entity/`, `tools/entity/`.
Question asked: can mobs and dropped items be simulated as one set-based SQL statement per phase per tick, and does it scale
better than vanilla / Purpur? Short answer at the bottom ([Verdict](#verdict)).

## Schema (`sql/500_entity_schema.sql`)

| Object | Purpose |
|---|---|
| `mc.entity_type_param` | per type: kind, bounding box, gravity (item 0.04, mob 0.08), tracker update interval (item 20, mob 3), delta encoding, tracking range, max age, walk speed |
| `mc.entity` (fillfactor 50) | one row per entity: position, velocity, rotation, `on_ground`, `born_tick`, `pickup_at`, `phys_tick` (lazy gravity), `deep_sleep`, goal (`gx,gz,goal_until`), chunk cell, last-sent tracker state (`sent_q*`, `sent_v*`, `sent_yaw/pitch`, `last_sent_tick`), `data jsonb` |
| `mc.block_class` / `mc.solid_mask` | per block state: solid + friction; per 16³ section a 512-byte solidity bitmask (unlogged), built lazily, invalidated by trigger on `mc.chunk_section` |
| `mc.entity_viewer_cell`, `mc.entity_cell_viewer` | players ↔ chunk cells in their interest area, maintained incrementally |
| `mc.entity_tick_log` | per tick, per phase milliseconds |

Only `(cx,cz)` is indexed on the hot table (so updates stay HOT); partial indexes serve "awake", "new", "has goal", "zombie".

## Tick pipeline (`mc.entity_tick(p_tick)`)

1. `entity_viewers_refresh`: incremental interest sets.
2. `entity_ai`: wander goals (hash-based, staggered), zombie chase of the nearest player within 16 blocks every 5 ticks.
3. `entity_spawner` (every 40 ticks, cap 8 mobs per 7×7 chunks), `entity_despawn` (every 20 ticks).
4. `entity_physics_ids`: one read-only statement computes new state for all active entities into arrays, then one
   `update … from unnest(…)`. Entities in deep sleep are not read at all; block changes wake them (trigger on `mc.block_event`).
5. `entity_tracker`: builds each packet once per entity, fans it out as one `play_out` row per viewer per tick.
6. `entity_pickup`: every 4th tick per player (`take_item_entity`, inventory slot packet, delete).

## Physics (matches vanilla `ItemEntity` / `Entity.move`, from bytecode)

Per tick for an active entity (items; mobs use their own gravity and walk-speed driven horizontal velocity):

```
vy  -= g                       (g = 0.04 items)       applied BEFORE the move
move(v)                        collision sweep, axis order Y, then X before Z if |vx| >= |vz| else Z before X
                               collided movement applied only if its squared length > 1e-7
f  = 0.98f                     (cast to double)
if on_ground: f = friction(block below) * 0.98f        (float product; 0.6 default, ice 0.98, slime 0.8, blue ice 0.989)
vx *= f; vz *= f; vy *= 0.98f
clipped axis velocity = 0; landing zeroes vy; bounce vy *= -0.5 only when on ground and vy < 0
on_ground = vertical movement was clipped while moving down
sleep: if on_ground and vx²+vz² <= 9.999999747378752e-06, skip move+drag unless (tick + id) % 4 == 0
       (gravity keeps accumulating meanwhile, which is what `phys_tick` reproduces lazily)
```

`mc.entity_sweep` / `mc.entity_move` do the axis sweeps against the section bitmasks (`get_bit`), so one entity costs a handful of
bit probes rather than block lookups.

## Verification against real vanilla 26.3

Method: a real vanilla server driven over RCON (`tools/entity/rcon.py record`) records per-tick positions/velocities of four
scenarios; `tools/entity/model.py` (Python reference) and the SQL replay (`tests/sql/510_entity_physics.sql`) are compared with them.

| Scenario | Max position deviation, SQL | Notes |
|---|---|---|
| free fall onto floor | 0 | exact |
| resting item (sleep/wake cadence) | 0 | wake phase is `id % 4` dependent, set per scenario |
| slide on floor (friction) | 0 (Python model 3.7e-8 before SQL port) | |
| wall hit | 0 | |

Velocities match to 1e-9 … 1e-6 while observable. Wire format: the `add_entity` + item `set_entity_data` bytes for an item are
**byte-identical** to captured vanilla packets (`tests/sql/530`), the `LpVec3` encoder re-encodes captured bytes exactly,
and the tick-20 cadence (motion packet, then position sync) equals vanilla's order.

## What is faked / not modelled

* No item merging, no entity-entity collision or cramming, no water/lava/ladders/cobweb, only full-cube solidity (no slabs, stairs, fences), no step-up.
* Mob AI is wander + straight-line chase, not pathfinding, no real vanilla goal system, no mob-specific behaviour (breeding, loot, damage, drops).
* Solidity is a name-regex heuristic (`mc.block_class`: 1053 of 1286 states solid), not the real collision shapes.
* Tracker: tracking ranges (6/10/8 chunks) are from memory, not verified; resting items send nothing (vanilla sends occasional extra checks and wobble motion packets, so deep sleep saves bandwidth versus vanilla: a deliberate deviation); `entity_position_sync` layout verified on item samples only, one captured cow packet did not parse, so the mob layout is unverified.
* Spawner spawns at the player's height and ignores light, biome and spawn rules; pickup is checked every 4th tick, not every tick; walk speeds are approximate.
* The prototype does **less** work per mob than vanilla (no pathfinding, no collision with other entities), so per-mob SQL cost below is understated.

## Benchmarks

Machine: 4 real CPUs shared with other workers (load average 3–5 during runs), PostgreSQL 16, one backend per tick. Treat numbers as ±30 % noisy.
Reproduce: `psql -v players=P -v rest=R -v mobs=M -v falling=F -v ticks=100 -f tests/bench/entity/bench_tick.sql`.
Budget: 50 ms per tick.

### SQL, whole entity tick (per tick, milliseconds)

| Scenario | total avg | p50 | p99 | notes |
|---|---|---|---|---|
| 500 players (100×100 chunk world) + 4,984 resting items | 16.4 | | | viewers 10.9, physics 0.5, tracker 0.14, pickup 4.9; WAL ≈ 88 KB/tick |
| 500 players + 2,000 mobs | 131 | 105 | 476 | viewers 19.8, physics 56.9, tracker 51.5 (spiky on 3-tick beats), pickup 2.8; ≈ 687 entities processed/tick; WAL ≈ 614 KB/tick |
| 1 player, 2,000 mobs within ±40 blocks | 106 | | 329 | 711 awake |
| 1 player, 5,000 resting items | 4.4 | | | all in deep sleep |
| 1 player, 7,000 mobs + 3,000 resting items | 204 | | 485 | 1,822 awake; WAL 1.2 MB/tick; 171k dead tuples |
| physics only, 2,000 falling items | ≈ 52 | | | ≈ 17 µs/entity (≈ 33 µs/row on 10k bursts) |
| physics only, 5,000 resting items | 1.9 | | | steady state; first tick builds the solidity masks (~2 ms each, one-time) |

Before the optimisation passes the 500-player/5,000-item case was 65.8 ms; the large wins were: array-driven update instead of
joined update, trigger-invalidated masks, RETURNS TABLE inlinable functions (OUT-parameter record functions are not inlined, 23–33 µs/call),
correlated `LIMIT 1` probes, partial index on awake entities, lateral `OFFSET 0` probes in the tracker.

### Real vanilla 26.3 (same host, flat world, view distance 3, two probe players)

| Scenario | MSPT |
|---|---|
| empty | 2.8–3.1 |
| 2,000 cows | 44–50 |
| 5,000 resting items | 53–56 (cannot hold 20 TPS) |
| 7,000 cows + 3,000 items | 500–550, then Server Watchdog crash |

### Side by side

| Entities | Vanilla | SQL prototype |
|---|---|---|
| 5,000 resting items | 53–56 ms | 4.4 ms (12× cheaper) |
| 2,000 walking cows | 44–50 ms | 106 ms (≈ 2.2× dearer) |
| 7,000 mobs + 3,000 items | 500+ ms, crashes | 204 ms, survives, still 4× over budget |

## Verdict

**Does it scale?** Partly. The set-based design pays off exactly where vanilla is worst: large populations that mostly do nothing
(dropped items, idle mobs). Deep sleep with a partial index, lazy gravity and "one packet per entity, fanned out per viewer"
make 5,000 resting items cost 2–5 ms (12× cheaper than vanilla), and the interest-set join keeps 500 players with ~5,000
items at 16 ms. It also degrades gracefully where vanilla dies (10,000 entities: 204 ms, no crash).

**Where it breaks:** entities that are continuously awake. Cost is ≈ 150 µs per awake mob per tick versus vanilla's ≈ 22 µs, so
about 300 awake mobs consume the whole 50 ms budget, and the prototype still skips pathfinding and collision, so a faithful
version would be worse. Causes: row updates (every awake entity writes a new tuple: WAL 0.6–1.2 MB/tick, dead tuples to vacuum), the
`entity_move` plpgsql function (≈ 14 µs per call), and the tracker packet building (51 ms at 2,000 mobs with 500 players). Parallel
query was already shown weak in this project, so this does not get fixed by cores.

**It does not by itself meet the "match Purpur" goal for mobs.** It can for items and sleeping populations.

**Next optimisations, in order of expected payoff:**
1. Take the write cost out: UNLOGGED `mc.entity` (entities need not survive a crash) or a tiered table (hot awake entities in a small unlogged table, sleepers in the main table).
2. Replace plpgsql `entity_move` with a specialised flat-floor/free-fall path in pure SQL (most walking mobs touch only the floor), keeping the general sweep for the rare cases.
3. Tracker: send mob movement only for entities with viewers (already so) and batch the per-viewer fan-out for cells with many viewers, raise the mob update interval under load.
4. Item pickup via an item-cell index rather than per-player scans (4.9 ms at 500 players).
5. Aggressive autovacuum or periodic `VACUUM` of `mc.entity` to bound the dead tuples.

## Update: re-measured against the real server (docs/PERF-MOBS2.md)

The "150 us per awake mob" and the 106 ms row above are the prototype before the lanes (docs/PERF-ENTITY.md) and the autonomous lanes (sql/940, docs/PERF-MOBS2.md).  Re-measured, CPU per tick of the
entity tick (dbcraft, 3 repetitions, steady state) against the CPU of the real vanilla server's thread (3 repetitions, the machine loaded: load 8-24, so vanilla's wall-clock tick times are not usable):

| scenario | vanilla | dbcraft (this branch) |
|---|---|---|
| 2,000 awake walking cows, a viewer in range | 65.6 ms | 10.9 ms (5.5 us per mob; the tree before: 33.0) |
| 5,000 awake walking cows, a viewer in range | 178.6 ms | 18.2 ms (3.6 us per mob; before: 57.4) |
| 5,000 resting items | 96.9 ms | 1.4 ms |
| 2,000 / 5,000 cows nobody can see | 5.2 / 10.1 ms | 12.0 / 19.2 ms (**still a loss**: vanilla's idle cow costs 2-2.6 us per tick) |

What changed: a walking or standing mob lives in a lane row (state, goal, chunk cell, the viewers' delta base) and a tracker step writes nothing; the next goal is drawn inside the lane; chunk borders
are crossed inside the lane when nobody notices; the WAL of 2,000 walking mobs fell from 17-44 KB per tick to about 0.  The "Next optimisations" list above is done except the pickup scan (items by cell:
partial index) and aggressive vacuum (the bench does what autovacuum does).  The prototype still models no pathfinding, goals, look-around, motion packets, sounds or collision, so the comparison
is not like for like (docs/PERF-MOBS2.md says what vanilla does per mob, from the jar).

### Update 2: lanes nobody can see are not simulated tick by tick (docs/PERF-MOBS2.md part 2)

Lazy lanes (sql/940: a lane farther than min(tracking range, view) + 1 chunks from every viewer is replayed every 32nd tick in closed form, proven equal to the tick-by-tick run on 400 random lanes in
tests/sql/940 L; whoever is about to look catches it up first) and a re-measurement against the real vanilla server, V D V D V D, vanilla `-Xms1G -Xmx2G`, CPU per tick, median of 3 at load 3-7:

| scenario | vanilla | dbcraft (this branch) |
|---|---|---|
| 500 / 2,000 / 5,000 cows nobody can see, **nobody connected** | 5.0 / 6.6 / 10.5 ms | **1.4 / 4.2 / 7.5 ms** (2.8 / 2.1 / 1.5 us per mob) |
| 500 / 2,000 / 5,000 cows outside the view of a connected viewer | 5.0 / 6.6 / 10.5 ms | 3.5 / 8.2 / 13.2 ms (**vanilla still 1.25x cheaper at 2,000 and 5,000**) |
| 2,000 / 5,000 cows in view | 81.5 / 195 ms | 9.5 / 20.6 ms |

A mob needs a floor that is uniform under its whole walk to get a lane: on ground with 2,000 scattered blocks the same 2,000 cows in view cost 215-238 ms instead of 10 (the scoreboard's mob rows ran on such a
world and saw 3-4x part 1's numbers; it is not the simulation distance).  `dbcraft.entity-mode` stays `off`: with no mobs at all `inline` costs 0.5-2 ms a tick (0 to 200 players) and defeats the quiet tick.
