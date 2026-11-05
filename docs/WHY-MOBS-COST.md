# Why mobs cost what they cost: dbcraft against vanilla 26.3, measured by scenario

Question (from the project owner): *figure out why mobs cost so much.*  This is an investigation, not a redesign.  It answers with numbers per scenario: a profile of where a dbcraft entity tick spends its time (per
phase, per function, per statement, rows, calls, WAL), what the real vanilla 26.3 server does for the same work (read from the jar with `javap -c -p`, plus a CPU profile and a walking-share measurement of the
real server), which of dbcraft's costs are inherent to "the server is PostgreSQL" and which are not, and what the achievable floors are.  Two small, safe fixes found on the way are in
section 9.  Raw results: `docs/why-mobs-results.txt` (dbcraft), `docs/why-mobs-vanilla.jsonl`, `docs/why-mobs-vanilla-jfr.{txt,jsonl}`, `docs/why-mobs-walkshare.jsonl` (vanilla).  Earlier work this builds on:
docs/ENTITY.md, docs/PERF-ENTITY.md, docs/PERF-MOBS2.md (parts 1 and 2), docs/SCOREBOARD-SUMMARY.md.

## 1. The short answer

A mob costs dbcraft one of **four very different prices**, depending on what it is doing and where it is.  Almost all of the "mobs cost so much" numbers are the second, third or fourth price being paid where
the first was expected.

| situation (2,000 cows, one viewer, CPU of the entity tick) | dbcraft | what it is made of | vanilla 26.3 (same machine) |
|---|---|---|---|
| **1. in view, flat uniform ground** (best case) | **5.1 ms** (4.7-5.1; 2.5 us per mob and tick) = 1.0 ms fixed + 2.0 us per mob | per tick about 36 goal events (a row update through SQL each, ~45-65 us all-in) = half of it; ~300 lane steps that build a packet (4 us each); one fan-out; three scans of the lane table | **40 ms** (0.80 cores; 8x more) |
| **2. just outside his view** (ring 100-140 blocks, view 5 chunks) | **1.7-3.9 ms** (0.9-1.3 ms per 500, 7.5 ms per 5,000; 1.3-1.6 us per mob and tick + 0.6 ms fixed) | the same goal events (~35 a tick) on mobs nobody sees (lazy lanes replay them every 32nd tick) | **4.75 ms**, of which 3.2 ms is the empty server's own cost; the cows are *inert* (section 7) |
| **3. ground with blocks on it: no lane** | **19 ms with 20 blocks scattered, 49 ms with 200, 141-145 ms with 2,000** (a mob that gets no lane: ~165 us per tick, plus ~11 ms per tick as soon as one mob is outside a lane) | the exact sweep, a generic tracker and a lane retry **every tick** for every mob that fails the uniform-floor test; two 12-CTE statements planned on every call | (not a different case in vanilla: the same ~40 ms) |
| **4. nothing to simulate** (entity-mode `inline`, no entity at all) | **0.35-0.65 ms** per tick (0 to 200 players), **now 0.04-0.07 ms, and nothing when nobody is connected** (section 9) | ~30 statements that find nothing: viewer refresh, goals, lanes, physics, tracker, pickup, despawn, clock row, log row | 3.2 ms (empty JVM) |

In plain language:

* **A dbcraft mob is cheap when its whole future is a formula.**  A walking cow on a floor that is uniform under its whole walk lives in one narrow "lane" row (position anchor, velocity, goal end, the viewers'
  delta base).  Its position at any tick is `x0 + g * (t - t0)`; a tracker step writes nothing and builds its packet from the row alone.  That is 2 us per mob and tick, 8 times cheaper than vanilla, **because
  vanilla does an order of magnitude more per mob** (collision queries, entity pushing, goal selection, pathfinding, tracker deltas; section 5) and dbcraft's model does none of it (section 6).
* **It becomes expensive when the formula stops holding or when events dominate.**  *Events* (a goal ends: draw the next one, test the floor, update the row; a chunk border is crossed) are each a statement
  pipeline over a row, 45-65 us of CPU, against a field write in vanilla.  There are 2-4 times more of them than in vanilla (a goal every ~62 ticks against a stroll every ~120, and none at all beyond 32 blocks
  from a player in vanilla).  When there is no lane (a block in the way, a step in the floor) every tick of the mob is an event: sweep, tracker and a lane retry, 165 us instead of 2.
* **Fixed costs make a few mobs look expensive.**  Every statement of the tick costs 10-60 us to set up even when it finds nothing; two of them are re-planned on every call (1.9 ms each) as soon as one
  mob is outside a lane; the empty tick runs ~30 of them.  This is why "no mobs" costs 0.5-2 ms and why 20 mobs on rough ground cost 15 ms.
* **The comparison with vanilla is lopsided in dbcraft's favour where mobs are seen and in vanilla's where they are not**, and in neither case like for like: vanilla simulates 8 goals, pathfinding and
  collisions for every ticked mob but not at all for mobs farther than the simulation distance from every player, and its cows farther than 32 blocks from a player **never walk** (measured: 0 % at 40-130
  blocks, 28 % within 24 blocks; dbcraft's walk 45 % of the time wherever they are).

## 2. Method, machine, and how far to trust the numbers

* **Machine**: 4 vCPU Firecracker VM (about twice as fast per core as the one of docs/PERF-MOBS2.md: the same 2,000-cow cell was 9.5 ms there and 5.1 ms here; **compare ratios with the older documents, not
  milliseconds**), PostgreSQL 16.15, `jit = off`, `shared_buffers = 128MB`, `autovacuum_naptime = 10s` (the docker configuration), own cluster in `/dev/shm`.  Other agents ran test suites and benchmarks on the
  other cores during most dbcraft measurements (load average 1-3.4; stated per cell in the raw file).  The vanilla cells ran at load 1.3-2.0.
* **dbcraft CPU** is the on-CPU time of the backend (`/proc/self/schedstat`), mean over 100 ticks (60 in the profile cells) after 150 warm-up ticks and a `VACUUM ANALYZE` (what autovacuum does within a
  minute; without it the plans of the first 250 ticks are wrong), one transaction per tick, on freshly generated flat chunks (`reset=1`).  `tests/bench/mobs2/bench.sql`, the harness of docs/PERF-MOBS2.md.
  The scheduler's CPU clock advances in 4 ms steps, so a single tick is quantised and p99 values mean little; means over 60-100 ticks are good to about +-0.1 ms.  Repetitions: two interleaved for every cell
  of the series (they agree within 10-20 %, except the ring cells: see below), one for the profile cells.
* **Profiles** (`-v profile=1`): `pg_stat_statements` with `track = all` and `track_planning = on`, `track_functions = all`, and `pg_stat_user_tables` deltas.  **The instrumentation is not free**: it costs
  15-25 us per statement execution and per function call, +17 % on the 2,000-cow in-view cell (5.5 against 4.7 ms) and up to 2.4x on a cell made of many tiny statements (ring: 3.9 against 1.7 ms).  So the
  CPU numbers come from separate runs without instrumentation, and the profile tables are used for *shares*, not for absolute values.  `pg_stat_statements` times include only the executor; planning is
  the separate `plan_ms` column.
* **WAL** is the *insert* position difference (`pg_current_wal_insert_lsn()`).  **The earlier harness used the write position (`pg_current_wal_lsn()`), which advances in 8 kB steps when the WAL writer
  flushes, and reported "WAL about 0" for the in-view cells; the real number is 12 KB per tick at 2,000 cows** (36 updates of a logged 300-byte lane row).  Fixed in `bench.sql` and `empty.sql`.
  (The other benchmarks of `tests/bench/` that print WAL use the old function and are unchanged.)
* **Vanilla**: the real 26.3 server, `-Xms1G -Xmx2G`, flat world, view distance 5, simulation distance 10, one probe client (`tools/entity/probe_client.py`), cows summoned over RCON, 30 s settle, 30 s
  window, CPU of the `Server thread` from `/proc` (jiffies).  **One repetition per cell**, no alternation with the dbcraft runs (so both sides had "their" load); the JIT warm-up is part of the window.
  A JFR recording (`jcmd JFR.start settings=profile`, 30 s, 2,246 samples of the server thread) gives the phase split of the 2,000-cow cell.

## 3. What a dbcraft mob tick is (anatomy, in the terms the profiles use)

One `mc.entity_tick(t)` (sql/550) runs, in order: the viewer refresh (who looks at which chunk cell: `mc.entity_viewer_cell`, `mc.entity_cell_viewer`), the legacy lane flush, the AI (`entity_ai_ids`: goal
draw for entities outside lanes and for chasing zombies), the spawner (if on), the despawn scan (every 20th tick), **`mc.entity_auto_try`** (may a mob that just got a goal start an autonomous lane?),
`mc.entity_lane_try` (the older lanes of sql/541), **`mc.entity_lane_step` -> `entity_auto_run`** (the lanes: the segments that ended, then the tracker steps of the lanes that are due), `entity_physics_ids`
(the exact sweep, for entities outside lanes), `entity_tracker` (the generic tracker, for them), a second `auto_try` / `lane_try` for what just landed, the pickup scan, the clock row and the log row.

* A **lane** (sql/541, sql/940) is the promise "this mob walks `x0 + g (t - t0)` until `goal_until`".  It exists only if the whole walk is on floor that is uniform at the level of the mob's feet
  (`mc.entity_floor`: per chunk the highest solid cell of each of the 256 columns, built on first touch).  A lane row is written **once per segment**, not per tick; a tracker step (every 3rd tick for a walker)
  reads the row and writes nothing.
* An **event** is what ends a segment: the goal ran out (draw the next one: hash of (id, tick)), or the mob reached a chunk border.  Each event is a row update (`mc.entity_lane`, HOT) inside one big
  statement, plus the floor verdict and the cell bookkeeping; an eager lane near a viewer is replayed at once, a **lazy** lane (nobody can see it: farther than `min(tracking range, view) + 1` chunks from every
  viewer) only every 32nd tick, in closed form.
* A mob **outside a lane** is an entity in the exact sweep (`entity_physics_ids`: collision against the 16^3 solidity bitmasks, one array-driven `UPDATE` of the wide 40-column row), the generic tracker
  (a 12-CTE statement: delta against the last sent state, packets, fan-out, another `UPDATE` of the wide row), and a lane retry (`auto_try`, `lane_try`) every tick.

## 4. The scenarios

All numbers: dbcraft CPU per entity tick, mean, ms.  "Profile" shares come from the instrumented runs.

### 4.1 Scenario 1: 2,000 cows in view, flat uniform ground (the best case)

CPU **4.65 ms** (this run), **5.08 / 5.06 ms** (the two series repetitions at load 3), 3.7 ms in a first quiet test run: **about 2.3 us per mob and tick**.  Scaling (two repetitions each, median):

| cows in view | 0 (exit taken, section 9) | 500 | 2,000 | 5,000 |
|---|---|---|---|---|
| CPU ms per tick | 0.00 | 2.0 | 5.07 | 11.2 |
| per mob | | 4.0 us | 2.5 us | 2.2 us |

A line: **1.0 ms fixed + 2.05 us per mob** (500 -> 2,000: 2.07 us; 2,000 -> 5,000: 2.04 us).  About 15 % of the mobs have a due step in a tick; ~1.8 % have a goal event.

Per phase (`mc.entity_tick_log`, wall ms): everything before the sweep 6.5 (this is where the lanes live: refresh, flush, AI, despawn, `auto_try`, `lane_try`, `lane_step`), physics 0.02, tracker 0.04, pickup 0.07.
By function and statement (profile run, 60 ticks, instrumented ms per tick; the whole tick is 5.5 instrumented against 4.65 plain):

| what | ms | calls | notes |
|---|---|---|---|
| `entity_auto_run` (all lanes) | 6.28 (self 4.28) | 1 | |
| - the replay statement (`with s as materialized ...`): the **goal events** | 2.80 | 1 | ~36 lane rows updated per tick (all HOT): **78 us per row all-in**; the statement is run every tick (>= 1 due), its set-up is ~0.7 ms of it |
| - the step statement (`with cand as ...`): packets of the due mobs | 1.31 | 1 | ~300 due mobs a tick, 4 us each; 28.6 calls of `epkt_mob_move` (the first step of a segment), the rest is `phead \|\| dx \|\| dz` |
| - the "what is due" probe (`bool_or` over the 2,000 eager lane rows) | 0.49 | 1 | one scan of the lane table |
| - fan-out of the per-cell blobs (`entity_fan_cells` + `insert into play_out`) | 0.67 + 0.22 | 1 | 95 buffer hits; 1 `play_out` row, 4 KB |
| - cell crossings: `update mc.entity ... from mc.entity_lane` | 0.13 | 0.98 | 5.5 wide-row updates a tick (the mob reached a chunk border and the viewers stay the same) |
| `entity_floor3` (uniform-floor verdict of the 3x3 chunks) | 0.48 | 10.7 | 45 us per call; one per segment that changes cell |
| `entity_view_same` (do the viewers of both cells coincide?) | 0.36 | 5.5 | 66 us per call |
| `entity_watched` (may anybody see this cell?) | 0.32 | 36 | 9 us per call |
| viewer refresh, despawn, pickup, mode probes, log and clock row, AI (2 `UPDATE`s that find nothing) | 0.09 + 0.06 + 0.08 + 0.04 + 0.04 + 0.14 | 1 each | the fixed part |

Rows and WAL per tick: `mc.entity_lane` **36 updates (all HOT), 3 sequential scans = 6,000 rows read**, 42 index tuples; `mc.entity` 5.5 updates (not HOT), 10 index probes; `mc.entity_floor` 96 probes; 1 `play_out`
row (4 KB); **WAL 12 KB** (the logged lane row, 36 x ~330 bytes).  Calls per tick: ~12 PL/pgSQL functions once each plus the per-event functions above; ~25 statements executed.

Reading it: **half of the tick is the goal events** (the replay statement and the floor verdicts: 2.8 + 0.5 + 0.4 + 0.3), **a quarter is the steps** (1.3 + fan-out 0.9), the rest is fixed overhead and the lane
table scans.  There is no tracker, physics or AI work at all for lane mobs.

### 4.2 Scenario 2: the same cows outside the viewer's view (one chunk of margin)

Cows on the square ring 100-140 blocks from the one viewer (6.25-8.75 chunks; view distance 5, cow tracking range 10: nobody sees them).  The band at chunk distance 6 (`min(10, 5) + 1`) stays eager (about
30 % of the ring's mobs), the rest is lazy.

| cows on the ring | 500 | 2,000 | 5,000 |
|---|---|---|---|
| CPU ms, repetition 1 / 2 | 1.27 / 0.92 | 3.19 / 3.88 | 7.75 / 7.50 |
| first cell run (60 ticks) | | 1.65 | |
| per mob | 2.2 us | 1.6 us | 1.5 us |

A line again: **0.6 ms fixed + 1.3-1.6 us per mob**.  The tick-to-tick spread is large (p50 0.65-3.4 ms, p99 10-16 ms: the every-32nd-tick replays, vacuum plan invalidations), and the two repetitions of the
2,000 cell are 20 % apart (1.7 and 3.9 in the single runs, 3.2 and 3.9 in the series): treat 2-4 ms as the range.

Profile (instrumented 3.9 ms): `entity_auto_run` 3.76, of which the replay statement **2.2 ms for ~35 events a tick (63 us each)**; the step statement only 0.16 (nobody is due: the eager band is outside
the viewer's box), probes 0.17, fan-out 0.34+0.05 (0.7 blob a tick: the lanes of the band); `entity_floor3` 0.48 (11 calls); `auto_try` 0.33, tracker 0.28, physics 0.26 for the ~0.1 mob a tick that left a
lane at the edge of the band; the rest as before.  Rows: **35 lane updates a tick (all HOT), no seq scan of the lane table (the probes are index-only)**, 743 index tuples, WAL 10 KB.

**The cost here is events and nothing else**: the same 35 goal events per tick as in view, minus every step.  The cost of an event does not depend on whether anybody can see it.

### 4.3 Scenario 3: ground with blocks on it (no lane)

The scoreboard's edit scenario left 2,000 stone blocks scattered over +-45 blocks on the ground the mob scenarios then ran on (`bench.sql -v scatter=N` reproduces it).  A mob gets a lane only if every
column of its walk (footprint: the segment's bounding box plus the cow's 0.9 width) has its highest solid cell one below its feet.

| blocks scattered | 0 | 20 | 200 | 2,000 |
|---|---|---|---|---|
| mobs outside a lane (of 2,000) | ~0 | 20 | 206 | 781 |
| CPU ms per tick, rep 1 / rep 2 | 5.07 / 5.06 | **20.1 / 19.6** | **50.1 / 48.4** | **145.5 / 141.2** |
| per mob outside a lane | | 755 us | 219 us | 180 us |

The fit is **11 ms fixed + 166 us per mob outside a lane** (200 -> 2,000: (141-48)/575 = 162 us; 20 blocks sit on the line).  A walking segment survives only if none of its ~11 columns (the footprint of a 5-block walk of a 0.9-wide cow) holds a block: with 2,000 blocks scattered (21 % of the
columns) 0.79^11 = 7 % do.  In a real built-up world the cows are not the only mobs with this problem: chasing zombies (re-aim every 5 ticks) are never in an autonomous lane at all.

Profile of the 2,000-block cell (instrumented, 133 ms; **783 awake mobs outside a lane**; per mob and tick 165 us):

| what | ms | calls | per call |
|---|---|---|---|
| `entity_auto_try` (2 calls: before and after the sweep) | **77.1** (self 60.0) | 2 | 38.5 ms |
| - `entity_floor_build` statement (candidates, `not exists` floor with `tops`) | 43.7 | 2 | 21.8 ms |
| - the candidate + `entity_floor_ok` statement | 29.3 | 2 | 14.7 ms |
| - `entity_floor_ok` (SQL function, 773 calls) | 17.2 | 773 | 22 us (9.9 us as a statement; the rest is executor start) |
| `entity_physics_ids` | **31.9** (self 21.6) | 1 | the sweep statement 24.6 ms, the array `UPDATE` of 774 wide rows 4.5 ms |
| - `entity_move` (plpgsql, per mob) | 10.2 | 769 | 13.3 us |
| `entity_tracker` (generic) | **14.1** | 1 | the 12-CTE statement 11.1 ms, **WAL 99.7 KB** (it rewrites 7 `sent_*` columns of the wide row) |
| `entity_lane_try` | 4.3 | 2 | 2.2 ms |
| `entity_auto_run` (the 1,245 mobs that do have a lane) | 6.1 | 1 | as in scenario 1 |

Rows and WAL: `mc.entity` **1,070 updates per tick (794 HOT)**, **5,018 index probes** (6 per mob: the same wide row is read by the sweep, the tracker, `auto_cand` twice and `lane_cand`), `mc.entity_floor`
4,417 probes, `solid_mask` 863; **WAL 250 KB per tick** (physics 109 KB, tracker 100 KB).  The wide row is 230 bytes and every awake mob rewrites it every tick.

Where the fixed 11 ms comes from (profiles of the 20-block and 200-block cells, `plan_ms` is planning time): as soon as **one** mob is outside a lane, `entity_physics_ids` and `entity_tracker` run
their big statements, **each re-planned on every call: 1.9-2.1 ms of planning per statement per tick** (the executor part is 1.3 and 0.65 ms for 20 mobs); `auto_try` runs three statements over the candidate ids
(5.3 ms for 20 mobs: 1.97 floor-build probe + 1.68 candidate/floor verdicts + `entity_floor_ok` 48 calls); `lane_try` 0.7 ms; the lane step 7.7 ms (the same lanes as in scenario 1, more floor verdicts).  The
profile of the 20-block cell sums to 19.9 instrumented ms against 5.5 for the same cell without blocks.  (Section 9: generic plans for the two big statements take ~2 ms of the 11 away.)

**The negative result worth stating**: the no-lane cost is not "the sweep is slow" (a sweep step is 13 us) but that a mob outside a lane is touched by **five statements per tick, each with its own probe of the
wide row and its own fixed cost**, forever, because nothing remembers that the lane test failed.  The part of the tick that tests it again and again (`auto_try` + `lane_try` + the verdict functions) is
**61 % of the cost** (`auto_try` 77, which contains the 17 ms of `entity_floor_ok`, plus `lane_try` 4, of 133 ms); physics and tracker are 35 % (32 + 14).

### 4.4 Scenario 4: the empty entity tick (inline mode, no entity at all)

`dbcraft.entity-mode = inline`, no entity row, the prototype spawner off, players standing still.  `tests/bench/mobs2/empty.sql`, 1,000 ticks per cell, hook = what `mc.server_tick` calls
(`if mc.entity_mode() <> 'off' then mc.entity_step(tick)`); CPU in us per tick on the cores of this machine (quantised: the mean over 1,000 ticks), wall in brackets (machine at load 0.9; round 2 at load 1-2):

| players | `off` | `inline` (full tick, before the fix) | `split`: player connection | `split`: entity connection |
|---|---|---|---|---|
| 0 | 12-19 (12-14) | **364 / 446** (374 / 433) | 70-75 (44-50) | 381-396 |
| 50 | 23 (14-17) | **477 / 665** (487 / 690) | 48-75 (43-59) | 424-630 |
| 200 | 4-15 (10-12) | **648 / 660** (636 / 659) | 45-67 (59-60) | 773-867 |

(Two rounds.  The docs/PERF-MOBS2.md section 5 numbers, 500-960 us at 0 players and 1.2-2 ms at 200, were from the older, slower machine; the shape is the same.)

Which statements run every tick even though there is nothing to do (profile, 300 ticks, 0 players, instrumented: `entity_step` **686 us**, of which `entity_tick` 661, plpgsql self 156):

| statement / function | us per tick (instrumented) | what it looks at |
|---|---|---|
| `entity_viewers_refresh` | 92 | `delete ... where conn_id not in (players)`; `select ... from mc.player left join mc.entity_viewer_cell where changed` (**O(players): 184 us at 200 players, 2 seq scans of 200 rows**) |
| `entity_ai_ids` | 125 | two `UPDATE ... FROM (select ... from mc.entity ...)` that find no row (the zombie chase one joins `mc.player`) |
| `entity_lane_step` -> `entity_auto_tick` -> `entity_auto_run` | 98 / 66 / 52 | a count over `mc.entity_viewer_cell`, `bool_or` over the eager lanes, an `exists` over the lazy lanes, one `select` of the legacy lanes |
| `entity_pickup_dispatch` -> `entity_pickup` | 95 | `entity_mode()` again, then `distinct on ... from mc.player cross join generate_series x2 join mc.entity ...` (**O(players)**: 75 us at 200) |
| `entity_mode` (4 calls) + `prop_int` (2) | 58 + 28 | each a `select value from mc.server_property where key = ...`: a seq scan of ~80 rows, 8-15 us |
| `entity_lane_flush`, `entity_despawn`, `entity_physics_ids` (one `exists` on a partial index), `entity_tracker` (one `exists`), 2x `auto_try`, 2x `lane_try` | 19 + 9 + 14 + 10 + 14 + 11 | each a plpgsql call with 1-2 trivial statements |
| `insert into mc.entity_tick_log` + `update mc.entity_clock` | 19 + 15 | two writes (the log row every tick, **for ever**: trimmed every 1,000 ticks) |

About **30 statements that cannot do anything**: 340 us of statement execution (instrumented) plus 150 us of PL/pgSQL interpretation (the self time of `entity_tick`).  With 200 players the viewer refresh and
the pickup scan alone are 400 of 830 us: both are O(players) per tick even if nobody moves.  And the hook defeats `mc.tick_quiet` (sql/800 required `entity_mode() = 'off'`), so an idle server with
nobody connected ran the full 123-statement tick instead of the quiet tick (0.125 ms).  Vanilla's empty server costs 3.2 ms of the server thread per tick, dbcraft's quiet tick 0.125 ms: it is the
default `off` that keeps that, and this section is why the default stays `off` until section 9.

### 4.5 Scenario 5: inline against split

`split` runs the entity tick on a second connection (`mc.entity_loop`), so the player connection's tick pays only the pickup bookkeeping.  Measured above: the player connection's hook costs **45-75 us** in
split mode, with or without entities and players (`mc.entity_apply_events`: one `DELETE ... RETURNING` of the pickup requests and a mode probe), against **0.36-0.66 ms empty and 4.7 ms with 2,000 cows in view** (scenario 1) in inline mode.
The entity connection pays what inline would have paid: 0.38-0.87 ms empty (it runs the whole fixed tick every tick on its own core), the scenario numbers above otherwise.  So split is a
**latency** fix (it takes the whole entity tick, up to 145 ms in scenario 3, out of the player tick), not a CPU fix: the sum is the same, plus a second connection's commit per tick.  With the sums below
50 ms (every cell but scenario 3 at 2,000 blocks) it holds the 50 ms tick at any size measured.  Split mode was not re-measured under load; its ownership rules are unchanged (docs/PERF-MULTICORE.md).

## 5. What vanilla does for the same work (read from the 26.3 jar with `javap -c -p`)

Per mob and tick, in the order the server runs them (`ServerLevel.tick`, `ChunkMap.tick`, `Mob`, `LivingEntity`):

1. **Is the mob ticked at all?**  `ServerLevel.tick` walks the entity tick list.  For every entity in it: `entity.checkDespawn()` (a `Level.getNearestPlayer(entity, -1)` scan of the players, **every tick, for
   every mob**), then `DistanceManager.inEntityTickingRange(chunk)`: only inside it (a chunk within the **simulation distance** of a player, 10 chunks by default) the entity is ticked.  **A mob in a chunk
   that no player is within 10 chunks of costs nothing at all** (no tick, no goal pass).  That is vanilla's "activation by chunk status"; dbcraft has none: a mob row is simulated (lazily, but it
   is) wherever it is.
2. **`Mob.tick` / `LivingEntity.tick` / `Entity.baseTick`**: counters, fire / water / lava / fluid state, block effects (`applyEffectsFromBlocks`), frost; `updateControlFlags` every 5th tick.
3. **`Mob.serverAiStep`** (from `LivingEntity.aiStep`): `noActionTime++`; `Sensing.tick`; **every second tick** (`(tickCount + entityId) % 2 == 0`, or `tickCount <= 1`) `targetSelector.tick()` and
   `goalSelector.tick()`, otherwise only `tickRunningGoals(false)`; then `navigation.tick()`, `customServerAiStep`, `moveControl.tick()`, `lookControl.tick()`, `jumpControl.tick()`.  `GoalSelector.tick`
   stops the running goals that cannot continue, then asks `canUse()` of **every goal that is not running**; a cow has eight (`FloatGoal`, `PanicGoal`, `BreedGoal`, `TemptGoal`,
   `FollowParentGoal`, `WaterAvoidingRandomStrollGoal`, `LookAtPlayerGoal`, `RandomLookAroundGoal`); `TemptGoal.canUse` calls `ServerLevel.getNearestPlayer(...)` unless cooling down.
4. **`RandomStrollGoal.canUse`** (cows: `WaterAvoidingRandomStrollGoal(1.0)`, interval 120): **`false` when `noActionTime >= 100`**, else `random.nextInt(reducedTickDelay(120)) == 0` (1 in 60 per
   evaluation, evaluations every 2nd tick: a stroll every 120 ticks on average); the target is a random point within 10 blocks horizontally and 7 vertically (`LandRandomPos.getPos(mob, 10, 7)`),
   reached by **A\* pathfinding** (`PathNavigation.createPath` -> `PathFinder.findPath`; `PathNavigation.tick` then follows the path every tick).
5. **`LivingEntity.aiStep`**: interpolation, the fluid checks (`getFluidHeight` twice), **`travel`** (`Entity.move`: block collisions of the box (`Entity.collide`, `getBlockCollisions`),
   step height, friction of the block below), `applyEffectsFromBlocks`, frost, **`pushEntities`** (`Level.getPushableEntities(entity, box)`: an entity query for every mob every tick; every overlapping mob
   is pushed; the cramming check above 24).
6. **Tracking** (`ChunkMap.tick`, `ServerEntity.sendChanges`): for every tracked entity a section-change test (`updatePlayers` only for entities that changed section or players that moved) and
   `sendChanges()` for entities in entity-ticking range: **work only when `updateInterval.test(tickCount)`** (3 for everything but items 20 and players 2) **or the synched data is dirty**: quantised
   position delta (`VecDeltaCodec`), rotation, `trackDelta` (every type but players: a velocity change of more than 1e-7 squared also sends `set_entity_motion`), a position sync every 400 ticks.

**Where vanilla's 40 ms for 2,000 cows in view goes** (JFR, 2,246 samples of the server thread, inclusive shares that overlap where they nest; `docs/why-mobs-vanilla-jfr.txt`):

| phase | share of the server thread |
|---|---|
| `ServerLevel.tick`: per-entity tick (`tickNonPassenger`) | **83 %** |
| - `LivingEntity.aiStep` | 72 % |
| - - `travel` / `Entity.move` (collision) | 42 % (collision shapes: `Entity.collide`, `getBlockCollisions`: 34 %) |
| - - `pushEntities` (entity-entity queries) | 8 % |
| - - `Entity.baseTick` and checks (fluids, block effects) | 16 % |
| - `Mob.serverAiStep` | 12 % (goal selectors 8 %, `PathNavigation.tick` 1.0 %, **A\* path computation 0.6 %**, `MoveControl` 0.9 %, `LookControl` 1.2 %) |
| - `checkDespawn` (nearest-player scan) | 1.3 % |
| tracking, main-thread part (`ChunkMap.tick`: 3.3 %, `ServerEntity.sendChanges` 2.2 %) | **3.3 %** (packets are written by the network threads) |
| chunk system (`ServerChunkCache.tick`, tickets: not mob work) | 13 % |
| top self-time frames | `Level.lambda$getEntities$0` 14.8 %, `BlockCollisions.computeNext` 11.4 %, `ServerChunkCache.getChunk` 5.5 % |

So **vanilla's cost per mob is collision and entity queries (about 60 %), not AI and not pathfinding (13 % and 0.6 %), and not the tracker (3 %)**: that is about 16-18 us per mob and tick (32-37 of the 40 ms, the rest is the chunk system).  dbcraft's
lanes skip exactly the collision and entity-query work (a lane is on a floor proven uniform; mobs do not push each other), which is the whole reason a lane mob is 8 times cheaper.  The viewer received
**148 KB/s, about 14,000 packets per second** from the 2,000 cows: 3,183 `move_entity_pos`, 2,444 `move_entity_pos_rot`, **5,455 `set_entity_motion`**, 3,127 `rotate_head`, 155 `sound`, 29
`entity_position_sync` (dbcraft: about 300 `move_entity_pos` / `rotate_head` packets a tick, 4 KB per tick = 80 KB/s for the same cows, no motion packets, no sounds).

What a mob **nobody can see** costs in vanilla is items 1-5 minus the tracker: the JVM measured **4.75 ms for 2,000 cows on the ring against 3.2 ms for the empty server**, i.e. **0.8 us per cow and tick** over the
fixed cost; those cows do not walk (next section), so the stroll goal fails at once, and no pathfinding runs.

## 6. What dbcraft does NOT model (so how much of vanilla's cost it does not pay)

| vanilla does | dbcraft |
|---|---|
| collision of every mob every tick (`Entity.move`, block shapes, step-up, edges): **42 % of the vanilla tick** | a lane is dead reckoning on a floor proven uniform; the exact sweep (full cubes only, no steps, slabs, fences) runs only for mobs outside lanes |
| entity-entity collision, pushing, cramming (`pushEntities`: an entity query per mob per tick): **8 % + part of the collision share** | none |
| baseTick checks: fluids, block effects, frost, invulnerability: **16 %** | none (no water, lava, ladders) |
| the goal system: 8 goals for a cow, `canUse` of all non-running goals every second tick, flags and locks, panic when hurt, tempting by wheat, breeding, following the parent: **8 %** | none: "wander" only (60 % of new goals walk 20-79 ticks, 40 % stand 40-139 ticks) |
| A\* pathfinding for every stroll: **0.6 %** at this stroll rate (it grows with the number of strolls and with obstacles) | none: a goal is a straight line (direction and speed from a hash of (id, tick)) |
| look-around: `LookControl`, `RandomLookAroundGoal`, `LookAtPlayerGoal` (head and body rotation packets) | yaw is the walking direction; one `rotate_head` with a rotation change |
| `set_entity_motion` for every velocity change (5,455/s here), `move_entity_pos_rot`, ambient sounds (155/s), dirty-data sync | `move_entity_pos` / `move_entity_rot` + `rotate_head` at the 3-tick cadence, a sync every 400 ticks |
| `checkDespawn` per mob per tick (nearest-player scan), random ticks, despawn rules, spawning by light and biome, breeding, loot, damage, ageing | a 600-tick despawn of mobs nobody sees; the prototype spawner |
| entity ticking range = simulation distance; **mobs beyond it cost nothing** | every mob row is simulated (lazily when nobody can see it) wherever it is |

## 7. Walking share, and whether the comparison is fair

* **dbcraft**: a goal is a walk with probability `dbcraft.entity_walk_prob` = 0.6 (20 + floor(r * 60) ticks, mean 49.5) or a stand (40 + floor(r * 100) ticks, mean 89.5): **45.3 % of the time walking**
  (29.7 / (29.7 + 35.8)), for every mob, wherever it is, with the exception of the lazy ones which replay the same hash chain.
* **vanilla**: `RandomStrollGoal.canUse` returns false from `noActionTime >= 100`, and `Mob.checkDespawn` resets `noActionTime` to 0 **only when the nearest player is closer than the category's no-despawn
  distance, 32 blocks for creatures** (read from the bytecode; the 128-block despawn distance does not matter for cows: `Animal.removeWhenFarAway` is false).  A cow farther than 32 blocks from every player
  therefore **never strolls** after its first five seconds.  Measured (`tools/entity/vanilla_walkshare.py`, 40 cows at each distance from one player, positions sampled over RCON once a second for 100 s, a cow
  "walks" in a second when it moved more than 0.5 blocks; the cows are 114 of the 120 summoned):

  | cows at (blocks from the player) | 8-24 | 40-70 | 100-130 |
  |---|---|---|---|
  | share of cow-seconds walking | **28.3 %** | **0.0 %** | **0.0 %** |

  So the "about 24 %" of PERF-MOBS2 (derived from packet counts of the 2,000-cow cell with cows spread over +-40 blocks, half of which are beyond 32 blocks) is the blend of 28 % near the player and 0 % far
  from him; and **vanilla's cows on the ring (scenario 2) are standing still**.
* **Is the comparison fair?**  Not like for like, in both directions:
  - *In view (scenario 1)*: vanilla's 40 ms includes the collision, pushing, baseTick, goal and tracker work dbcraft does not model (section 6), and about half of its cows (those beyond 32 blocks of the
    viewer: the scenario spreads them over +-40 blocks) are inert; dbcraft's 45 % walkers cost a goal event every 62 ticks.  The 8x is therefore the price of the *model*, not of the database: with the work
    dbcraft does not do taken out of vanilla's profile (collision, pushing, baseTick checks: about 65 % of the thread) vanilla would be at roughly 14 ms, about 3x dbcraft's 4.7-5.1.  (A rough
    subtraction from inclusive JFR shares, not a measurement.)
  - *Outside the view (scenario 2)*: vanilla's cows do not walk and cost 0.8 us each over a JVM of 3.2 ms; dbcraft's walk 45 % of the time and cost 1.3-1.6 us each over 0.6 ms.  **Per mob, dbcraft is 1.7-2x
    more expensive than vanilla's inert cow; in absolute terms at 2,000 cows it is below the JVM's own fixed cost (3.2 ms), which is why the earlier "vanilla wins 1.25x" has flipped on this machine
    (PERF-MOBS2 part 2: 8.2 against 6.6 ms; here 1.7-3.9 against 4.75).**  **What the walking costs** (`tests/bench/mobs2/why_walk.sh`: the same 2,000 cows with `dbcraft.entity_walk_prob` = 0, 0.38, 0.6, 1.0; share of time walking 0 %, about 25 %, 45 %, 100 %; CPU ms, two repetitions):

  | share of the time walking | 0 % (all goals stand) | about 25 % (vanilla near a player) | 45 % (default) | 100 % |
  |---|---|---|---|---|
  | on the ring (nobody sees them) | **0.75 / 0.91** | 2.7 / 2.1 | 3.0 / 2.9 | 4.8 / 4.6 |
  | in view | 1.6 / 1.7 | 3.9 / 4.5 | 5.1 / 4.7 | 6.8 / 6.3 |
  | WAL KB per tick (ring / in view) | 6 / 5 | 9 / 9 | 10 / 12 | 14 / 19 |

  So **three quarters of scenario 2's cost is the walking that vanilla's cows do not do there**: with its cows standing, as vanilla's are beyond 32 blocks, dbcraft costs **0.8 ms for 2,000 cows = 0.4 us
  per cow, half of vanilla's 0.8 us per inert cow** (and 0.8 against 4.75 ms in absolute terms); with vanilla's walking share near a player (25 %) it is 2.1-2.7 ms.  The model could make this
  fair at no cost to fidelity by copying the rule (no new goals beyond 32 blocks of a player: the mob stands, its lane needs no event after the first); that is a behaviour change (cows far from every
  player would stop wandering, as in vanilla) and was not made here.

## 8. Inherent, fixable, and the floors

| cost | inherent to the design? | fixable? | estimate of the floor | what it would take |
|---|---|---|---|---|
| **a goal event is a row update through SQL**, 45-65 us all-in (63-78 us per row including statement set-up) against a field write | **partly**.  A statement's set-up (10-60 us for an ordinary one, up to 0.7 ms for the 12-CTE lane statement) and a tuple update (heap + WAL 330 B + HOT check) cannot go below roughly 10-15 us per row in PostgreSQL (estimate). | yes, by making events fewer and cheaper | **~15 us per event** and 2-4x fewer events: the 2.8 ms of events at 2,000 cows in view -> 0.4 ms | keep the lane state of mobs in **array columns of a per-chunk-cell row** updated in bulk (one `UPDATE` per cell per tick instead of 36 row updates); draw goals in the same statement; vanilla-like rates (idle ~120 ticks, 25 % walking, none beyond 32 blocks) cut the event rate by ~2.5x |
| lane steps: a packet per due mob (4 us) | **yes** (a packet is a packet; vanilla builds the same) | slightly | 1.3 -> ~0.8 ms at 2,000 cows | build the packet blob per cell directly from arrays |
| three scans of the lane table per tick (6,000 rows, ~0.6 ms) | no | yes | -0.5 ms | a due-queue (`goal_until` bucket per tick) instead of scanning; the earlier attempt with an index on `goal_until` made every update non-HOT: use a small `id`-keyed bucket table or the array rows above |
| fixed statement set-up ~30 statements even when idle | **no** | yes, mostly done | empty tick **0.35-0.65 ms -> 0.02 ms** (section 9); non-empty ~1 ms -> ~0.5 ms | early exits per phase (`exists` probes; the AI does two `UPDATE`s that find nothing; pickup/refresh are O(players)) and dropping the per-tick clock/log rows |
| planning: two big statements re-planned every call (1.9 ms each) when any mob is outside a lane | no | yes, cheap | -2 ms (section 9) | `plan_cache_mode = force_generic_plan` (as the lane functions have since part 2) |
| **no lane**: 165 us per mob and tick + 11 ms | **partly**: a mob that collides with real obstacles needs a sweep (13 us/mob) and a tracker step; vanilla pays 18 us for a mob in the open too | yes, a lot | **~60-70 us per mob, ~3 ms fixed** with a negative cache (the lane test is 60 % of the 133 ms); **~15-25 us** with lanes that end at the first obstacle instead of refusing the walk | (a) remember the verdict: retry the lane only when the goal, the floor or the cell changes (the result of a lane and of the sweep are identical to 1e-9, tests 541 C / 940 C, so a later start is invisible on the wire); (b) a lane segment that ends where the sweep would hit a column with a different top, and a stand (velocity 0 lane) there: the cow stops at the block as it does today |
| mobs nobody sees: events only (35 a tick), 1.3-1.6 us per mob + 0.6 ms | **no** (the per-mob replay is a choice) | yes | **~0.1-0.3 us per mob** | **do not simulate what nobody observes**: keep unobserved mobs as `(seed, t0, x0, z0)` in a per-chunk-cell **population summary row** and replay (or, after a long absence, re-draw positions) only when a viewer, a block change or a border approaches; the goal draws are a hash, so the catch-up is a replay, bounded by capping the number of segments replayed |
| mobs beyond the simulation distance of every player | **no** | yes | 0 | vanilla's rule: do not tick them at all.  dbcraft needs the same "entity ticking range" test (a cell within 10 chunks of a viewer) in front of the lazy replay |
| WAL 12 KB per tick (lanes logged) | partly | yes | ~0 | `UNLOGGED` lane rows are not possible while the wide row says "I am in a lane"; either make that flag derivable (lane absent = not in lane) or drop the lane table on crash recovery and restart lanes from entity rows (the `mc.entity_auto_rebase` path) |
| 5 reads and 1-2 rewrites of a 230-byte row per awake mob (no lane) | **yes**, in a row store | yes, by not being awake | -- | the lane tables of the no-lane path (narrow rows, array updates) |

**Achievable floors with the fixes that are not redesigns** (negative cache, generic plans, early exits, due-queue): in view 2,000 cows ~3 ms (1.5 us per mob), outside the view ~1.5 ms, no lane at 2,000 blocks
scattered ~60 ms (from 141), empty 0.04-0.07 ms.  **With the redesigns** (cell rows with arrays, population summaries, no ticking beyond the simulation distance): in view ~1.5-2 ms, outside the view ~0.2 ms
and independent of the number of mobs, no lane ~30 ms.  The last row is the one that matters for real servers: a built-up world is where mobs live, and the ratio of 29 (141 against 5 ms) between a mob
outside and inside a lane is a larger factor than anything between dbcraft and vanilla.

## 9. The fixes made

### 9.1 The empty entity tick returns early; inline mode with no entity is quiet (sql/550, sql/800)

`mc.entity_tick` returns at once when `mc.entity` is empty and nothing could create an entity this tick (the prototype spawner is off, or nobody is connected for it to spawn for); the interest sets
(`mc.entity_viewer_cell`, `mc.entity_cell_viewer`) are emptied once if they were not (the first tick with an entity rebuilds them from the players' positions *before* it announces anything: the viewer
refresh treats a player without a row as new, so its whole view is "entering"); no row in `mc.entity_tick_log`, `mc.entity_clock` stays behind (the first tick with an entity re-anchors the lanes
that do not exist).  In split mode the commands of the player connection are still consumed first.  `dbcraft.entity_empty_exit = off` runs the full tick (for comparison and as a switch).
`mc.tick_quiet` (sql/800) accepts `inline` with no entity row: an idle server with nobody connected runs the 0.125 ms quiet tick again in inline mode.  `off` stays the default (`inline` with the
spawner on spawns mobs around every player, which changes what the server does; the early exit is for `inline` with `dbcraft.entity_spawner = off`: items, drops, containers).

**Proof** (`tests/sql/1010_entity_empty_tick.sql`, 27 checks; `tests/sql/550`, `800`, `970` adapted where they asserted "inline is never quiet" / "inline logs a tick"):
* a 220-tick history is run with the exit on and with it off: ticks of nothing, two cows, an item and a mob nobody sees appear, are discarded (removal packets from the interest sets), the world is empty
  again while the players move (a jump of 7 chunks), one leaves, one joins, then four mobs and an item appear in view of the new positions and walk for 100 ticks.  **Every `play_out` row of every tick for every
  viewer is byte-identical** (92 (tick, viewer) rows, hash of the concatenated bytes), as are the final entity rows, lane rows and both interest sets.  A second full-tick run equals the first (the harness
  is deterministic after a warm-up history: on a fresh database the lanes of the very first history start a tick or two later because floors and masks are built on first touch; that is the case with
  or without the exit).
* the exit is taken exactly when allowed (no entity and spawner off or nobody connected); spawner on with a player: the ticks run and the spawner spawns; a cow, a lane or `entity_empty_exit = off` run the
  full tick; the removal of the last entity still reaches the viewer; an empty tick consumes the split-mode commands.
* the first entity after 500 empty ticks and a long walk of a player is announced to exactly the player who can see it.
* `tests/sql/510, 530, 541, 550, 551, 940, 800, 970, 1010` pass; `tools/check_overrides.py`, `check_inlining.sh`, `check_fresh_migration.sh` are green (through `tests/sql/prun.sh`).

**Effect** (`tests/bench/mobs2/why_empty2.sh`, same database, alternating, 1,000 ticks, spawner off): wall microseconds per tick of the hook (CPU is below the resolution of the scheduler's clock: 0-80 us), round 1 / round 2:

| players | `off` | `inline`, full tick (`entity_empty_exit = off`) | **`inline`, early exit** | `split`: player connection | `split`: entity connection (CPU) |
|---|---|---|---|---|---|
| 0 | 8 / 14 | 296 / 535 | **50 / 73** | 27 / 36 | 3 / 43 |
| 50 | 8 / 17 | 521 / 700 | **39 / 51** | 26 / 49 | 2 / 60 |
| 200 | 23 / 17 | 745 / 1,003 | **35 / 55** | 29 / 36 | 55 / 4 |

(load 2.9 during this run, so the full-tick column is higher than in section 4.4.)  The early exit costs 35-75 us: a mode probe (8 us, twice: `mc.server_tick` and `mc.entity_step` both read the property),
`set_config`, the setting probes and two `exists` on empty tables; it **no longer depends on the number of players** (200 players: 745-1,003 us -> 35-55 us), which is 8-20 times cheaper.  With nobody
connected the server tick is the quiet tick (sql/800) and the hook is not called at all.  The remaining 35-75 us are the two property lookups of the server tick, which every mode pays (`off`: 8-23 us).

### 9.2 Generic plans for the physics and tracker statements (sql/510, sql/551)

**Found by the profile of scenario 3**: with `pg_stat_statements.track_planning = on` the two big statements of the no-lane path, the sweep (`with a as materialized ... entity_active(p_tick)`) and the generic
tracker (`with mv as materialized ...`), show **1.9-2.1 ms of planning per call, on every call** (custom plans: PostgreSQL keeps preferring them), against 0.65-1.3 ms of execution for 20 mobs.  The lane
functions had been given `plan_cache_mode = force_generic_plan` in part 2 (13.7 ms -> 1.4 ms); these two had not.  Measured A/B (`tests/bench/mobs2/why_ab.sh`, same database, alternating, CPU ms, two
repetitions per variant, the A column twice because A ran against B and against C; **load 3-4, spread +-1 ms: only differences of 3 ms and more mean something**):

| cell (2,000 cows in view) | A: as before | B: generic plans on sweep and tracker | C: generic plan on the sweep only |
|---|---|---|---|
| 20 blocks scattered (20 mobs outside lanes) | 18.2, 21.4, 20.9, 19.6 | 16.1, 17.4 | **15.9, 15.3** |
| 200 blocks (206 mobs) | 53.7, 49.4, 52.4, 54.6 | 50.1, 47.2 | 47.1, 54.1 |
| 2,000 blocks (781 mobs) | 138.9, 135.6, 136.7, 144.2 | 142.0, 132.1 | 138.6, 142.0 |
| flat, in view (no mob outside a lane) | 4.0, 4.8, 3.8, 5.4 | **5.3, 5.8** | 3.8, 5.0 |
| flat, ring | 2.9, 3.8, 3.6, 3.1 | 2.7, 2.8 | 2.6, 4.8 |

B (the tracker too) is 1-1.4 ms *slower* on the flat in-view cell in both repetitions (the generic plan for `e.id = any(p_ids)` is worse for the few mobs that leave a lane at a border), so **only the sweep
got it** (variant C, `sql/510`: `mc.entity_physics_ids` has only the tick as parameter, so the generic plan is the plan): **-4 to -5 ms (-22 %) at 20 mobs outside lanes, within the noise elsewhere**.
The tracker's 1.9 ms of planning stays; the real fix is not to run the tracker's big statement for a handful of ids (section 8: negative cache).  Equality: only the plan can differ, not the result;
tests 510, 530, 541, 550, 551, 940 pass unchanged.

### 9.3 Found, not fixed

* **The WAL numbers of PERF-MOBS2 ("about 0") were a measurement artefact** (write instead of insert position): see section 2.  The lane rows are logged; 12 KB per tick at 2,000 cows in view.
* **A first history on a fresh database differs in lane timing from every later one** (floor summaries and masks are built on first touch, at most 8 per call): harmless, but tests must warm up.
* **`mc.entity_viewers_refresh` and `mc.entity_pickup` scan all players every tick** whether anybody moved (184 and 75 us at 200 players): a "chunk changed" flag on `mc.player` would make them O(movers).
* **Lane updates, lane tests and floor builds are not remembered**: section 8.

## 10. Reproduce

```
export PGHOST=/tmp PGPORT=56537 PGUSER=postgres PGDATABASE=dbcraft_dev
DBCRAFT_PGDATA=/dev/shm/why/pg DBCRAFT_PGPORT=56537 tests/bench/entity/setup_db.sh dbcraft_dev   # then ALTER SYSTEM: shared_preload_libraries = pg_stat_statements, pg_stat_statements.track = all,
                                                                                                    # track_functions = all, jit = off, autovacuum_naptime = 10s; restart
tests/bench/mobs2/why_cells.sh 1 2 3 3a 3b            # cells 1-3: cpu run + profile run each (bench.sql -v profile=1), appended to docs/why-mobs-results.txt
tests/bench/mobs2/why_series.sh                       # the scaling series and the no-lane gradient, two interleaved repetitions
tests/bench/mobs2/why_empty.sh; tests/bench/mobs2/why_empty2.sh   # cell 4: the empty tick (before: exit = off; after), modes off / inline / split, 0 / 50 / 200 players
tests/bench/mobs2/why_ab.sh                           # A/B of the generic plans
python3 tools/entity/vanilla_mobs.py --dir /dev/shm/why/van --port 25971 --rcon 25972 --scenarios 0,2000v,2000n --settle 30 --window 30 --xms 1G --xmx 2G --out docs/why-mobs-vanilla.jsonl
python3 tools/entity/vanilla_mobs.py ... --scenarios 2000v --jfr 30     # then: python3 tests/bench/mobs2/jfr_phases.py <dir>/2000v.jfr
python3 tools/entity/vanilla_walkshare.py --n 40 --seconds 100         # walking share by distance from the player
tests/bench/mobs2/why_tests.sh                        # the tests the change touches, each through tests/sql/prun.sh
```

## 10. Second round: vanilla-like behaviour and the performance levers

The owner asked for the behaviour differences of section 7 to be removed and for the levers of section 8 to be pulled.  What follows is what was done, what changed **on purpose**, what is proved equal, and
the numbers, measured the same way as before (CPU of the backend, interleaved, two repetitions).  The machine was at load 6-7 during this round because other agents were running: **compare the columns of this
round with each other, not with section 4**, where the load was 1-3 and the same cells cost 25-40 % less.

### 10.1 Behaviour that changes on purpose (sql/942, `dbcraft.entity_ai = 'vanilla'`, now the default; `'wander'` is the old model)

| | before (`wander`) | now (`vanilla`) | where it comes from |
|---|---|---|---|
| goal selection | an event when a goal ends | a decision on an **evaluation tick**: `(tick - born + id)` even (every second tick) | `Mob.serverAiStep`: `(tickCount + entityId) % 2 == 0` |
| standing before a stroll | 40-139 ticks, then a coin flip (60 % walk) | **2 x Geometric(1/60) ticks (mean 120)**, then a stroll for certain: drawn in closed form from a hash of (id, tick) | `RandomStrollGoal.canUse`: `nextInt(60) == 0` per evaluation |
| a stroll starts only if | always | **a player (not a spectator) is within 32 blocks** | `RandomStrollGoal.canUse` is false from `noActionTime >= 100`; `Mob.checkDespawn` resets it only when the nearest player is closer than 32 blocks |
| where to | a random direction, 20-79 ticks at 0.06-0.1 b/t | **a random block within +-10 on both axes** (`nextInt(21) - 10`); the walk takes (octile path length) / 0.088 ticks and ends exactly on the block (no A\*: a straight line, no obstacles) | `LandRandomPos.getPos(mob, 10, 7)`; speed **measured on the real server**: 1.76 blocks/s at the 75th-99th percentile of the moving seconds (`tools/entity/walkshare_stats.py`) |
| nobody within 32 blocks | the mob wanders on | it stands; **with no player within 2 chunks it goes dormant**: no events, no scans, nothing simulated, until a player comes within 2 chunks (then it draws a wait) | vanilla: no tick at all beyond the simulation distance, no stroll beyond 32 blocks |
| a newborn | a goal at once | a wait first (stroll chance 1/60 per evaluation, not 1 at birth) | `tickCount <= 1` evaluates once |

Not modelled (deviations that remain): the 100-tick grace of `noActionTime` (a stroll may still start up to 5 s after the last player left the 32-block circle: dbcraft decides at the decision tick, with the
players as they are then); a stroll in progress when the last player leaves the simulation distance (vanilla freezes it, dbcraft finishes it, then goes dormant); pathfinding around obstacles (a straight line; a
block in the way stops the mob as before); the other goals; the dormancy radius of 2 chunks is the smallest square that contains the 32-block circle around any player position inside his chunk
(`least(2, simulation-distance)`).  Zombies keep the chase AI of sql/541 (re-aim every 5 ticks).

**Walking share, measured like the real server's** (`tests/bench/mobs2/walkshare.sql` = `tools/entity/vanilla_walkshare.py` on the entity rows: 40 cows at 8-24, 40 at 40-70, 40 at 100-130 blocks of one player,
sampled once a second, "walking" = more than 0.5 blocks in a second; series in `docs/why-mobs-walkshare-series*.jsonl`):

| | vanilla (100 s / 240 s) | dbcraft (100 s / 240 s; the cows' positions differ from run to run) |
|---|---|---|
| near (8-24 blocks) | 28.3 % / 21.4 % | 35.5 % / 21.9-26.8 % |
| mid (40-70 blocks) | 0.0 % | 0.0 % |
| far (100-130 blocks) | 0.0 % | 0.0 % |
| walking run, standing gap (near, 240 s) | 4.9 s, 6.8 s | 5.7 s, 6.1 s |
| speed while moving (blocks/s, 10th-99th percentile) | 0.88 - 1.79 | 0.97 - 1.76 |

(The near share falls with time in both: cows wander off the 32-block disc and stop there for good.)  The 100-second dbcraft figure is 7 points above vanilla's single run; the 240-second figures agree.  Test 1011
asserts 12-40 % near and exactly 0 beyond 32 blocks.

### 10.2 The levers

1. **Negative cache of lane attempts** (sql/940: `mc.entity.lane_nogo` / `lane_retry`, `dbcraft.entity_lane_retry`, default 8; 1 = the old behaviour).  A walking mob whose walk is not on uniform floor stays in the
   sweep; the verdict "no lane for this goal" is kept for 8 ticks, voided by a new goal (the verdict is about one `goal_until`) and by a block change within 2 chunks (the block-event trigger, `mc.entity_wake_apply`
   for split mode, and the floor-summary hook).  A refused mob is no longer asked by three statements every tick.
2. **Cheaper events**: the rate cut of 10.1 (goal events per tick at 2,000 cows in view: 36 -> 15.6, and none at all for dormant mobs).  Not done: lane state in per-chunk-cell array rows (10.5).
3. **Unobserved mobs cost nothing**: dormant mobs (10.1) have no events, are excluded from the lazy-slot probe (`entity_lane_lazy_idx ... and not dormant`) and from the eager scans (a dormant lane is lazy), and wake
   through a partial index by cell (`entity_lane_dormant_idx`) when a player enters within 2 chunks (`mc.entity_viewers_refresh`).  This is vanilla's "entities beyond the simulation distance cost nothing", without a
   per-cell summary row: a mob is its lane row, and a row that never changes costs nothing but its place in the table.
4. **Dirty-driven viewer refresh and pickup** (sql/500, 541, 550): row triggers on `mc.player` note joins, leaves and chunk changes in `mc.entity_view_dirty`; `mc.entity_viewers_refresh` looks at those players only
   (a view-distance change makes everybody dirty); the pickup scan is skipped when no item entity exists; the AI statements are skipped when no goal has expired / no zombie exists.  (One line in sql/836: a respawn
   that clears a player's interest row marks him dirty.)

### 10.3 Before / after (CPU ms per entity tick, 2 repetitions, 400 warm-up ticks, load 6-7)

OLD = `dbcraft.entity_ai = wander` and `dbcraft.entity_lane_retry = 1`; RETRY = wander and the cache (isolates lever 1); NEW = the defaults.

| cell | OLD | RETRY | **NEW** | NEW / OLD |
|---|---|---|---|---|
| 500 cows in view | 2.8 / 2.9 | | **2.7 / 2.4** | 0.89 |
| 2,000 cows in view (+-40 blocks of the viewer) | 6.3 / 6.7 | | **5.6 / 5.6** | 0.86 |
| 5,000 cows in view (+-72 blocks) | 14.9 / 13.6 | | **7.2 / 6.0** | 0.46 |
| 2,000 cows on the ring (nobody sees them) | 4.7 / 4.0 | | **0.77 / 0.79** | **0.18** |
| 5,000 cows on the ring | 8.2 / 9.9 | | **1.26 / 1.03** | **0.13** |
| 2,000 cows in view, 20 blocks scattered (no lane for ~20 mobs) | 23.4 / 24.2 | 19.2 / 18.1 | **16.0 / 16.0** | 0.67 |
| ... 200 blocks | 72.2 / 71.7 | 38.6 / 41.3 | **25.6 / 30.6** | 0.39 |
| ... 2,000 blocks | 201 / 201 | 96.5 / 94.1 | **47.8 / 49.1** | **0.24** |
| WAL KB per tick: 2,000 in view / ring / scatter 2,000 | 13 / 11 / 245 | | **6 / 0 / 111** | |
| lane rows updated per tick (events), 2,000 in view | 36 | | 15.6 | |

* **Outside the view: 5-8 times cheaper** (0.4 us per mob, WAL zero): the mobs are dormant, there are no events.  This is the cell that was "still a loss" against vanilla's idle cow in PERF-MOBS2.
* **In view the gain is smaller (14 % at 2,000, 54 % at 5,000)**: only the cows within 32 blocks of the viewer act (about half of the 2,000, 15 % of the 5,000 because that scenario spreads them over +-72 blocks),
  and what is left is mostly **fixed cost of the lane statements**.  Profile of the NEW 2,000-cow cell (instrumented): the replay statement 2.1 ms for ~12.5 events (most of it set-up and the scan of the lane
  table), the step statement 0.75, the fan-out 0.6, the "what is due" probe 0.4.
* **No lane: the cache alone halves it** (RETRY: 201 -> 95 ms at 2,000 scattered blocks), the vanilla rates halve it again (fewer walking mobs, dormant mobs stand: 49 ms, 4x below OLD).  The fixed part of the
  no-lane path remains (the tracker statement is still planned on every call).
* **Lever 4** (`tests/bench/mobs2/why2_viewers.sh`, 5 resting items, N players standing still, old tree against new): 50 players 0.07-0.17 -> 0.06 ms, 200 players 0.12-0.17 -> 0.04-0.08 ms per tick: the O(players)
  refresh and pickup scans are gone.  (The CPU clock quantum is 4 ms: these small means are +-0.02 ms.)

### 10.4 What is proved equal, what is not, and the mutation checks

* **Negative cache (`tests/sql/1012`)**: the same 400-tick history on rough ground (500 scattered blocks, 80 cows, a block placed and removed in the middle) with `dbcraft.entity_lane_retry` = 1 and 8: **the exact
  position of every mob after every 20th tick is the same to 1e-9** (a lane is the closed form of the sweep), and **the packets the viewer receives agree as a multiset per tick in at least 99 % of the cases
  (9,765 of 9,767 (tick, viewer, packet) groups in the run measured)**: not byte-identical, because a mob that starts its lane later is tracked by the generic tracker a few ticks longer; the differing groups
  are first steps.  A block change voids the verdict in the same tick; a new goal voids it.
* **Vanilla AI (`tests/sql/1011`)**: the wait distribution (mean 120, evaluation parity, geometric tail), the decision (stroll target uniform over the 21 x 21 offsets, speed, yaw, duration; a player at 40 blocks or
  a spectator: no stroll; nobody within 2 chunks: dormant; newborn and arrived mobs: wait), the walking share by distance over 150 s, dormancy and wake (lane rows and rows outside lanes; a wait drawn from the
  waking tick), **lazy lanes against the tick-by-tick run in vanilla mode (positions and dormancy identical to 1e-9)**, and the old model still reachable.
* **Not "equal" on purpose**: everything in 10.1.  `tests/sql/940` and `1010` pin the lane machinery against the old model (`set dbcraft.entity_ai = 'wander'` at their top, with a comment): they test lanes, not rates
  (940 A compares `mc.entity_goal` with the old AI draw).  The other entity tests (510, 530, 541, 550, 551) pass unchanged with the new default.
* **Mutation checks** (`tests/bench/mobs2/mutants.sh`, `docs/why-mobs-mutants.txt`): seven mutants, each applied to a scratch database and run against the test: no dormancy, no 32-block test, spectators counted, a
  wrong geometric rate, a wrong evaluation parity, no wake-up, a verdict that lasts 5 ticks too long: **all killed**.  Checked by hand while writing the tests: removing the block-event invalidation (killed by
  1012 B) and ignoring the goal in the verdict (killed by 1012 C).  The floor-summary hook that also voids verdicts is redundant with the block-event trigger (a mutant without it survives, as it should); it
  stays as a second path for changes that do not go through `mc.block_event`.

* **Whole suite** on the final tree (`tests/sql/prun.sh`, JOBS=3, 12 minutes): 83 files, **3,225 checks, all passing**, and `tools/check_overrides.py` (60, all listed), `tools/check_inlining.sh` and
  `tools/check_fresh_migration.sh` green.

### 10.5 What was not done, and the floors now

* **Lane state in per-chunk-cell array rows**: not built.  With the vanilla rates the events are 12-15 a tick in view and 0 outside; what remains is statement fixed cost (set-up, scans of the lane table), which an
  array row would reduce only together with a restructuring of the lane statements (a due-queue instead of three scans, one statement for events and steps).  Estimated floor for 2,000 cows in view: ~2.5 ms (from 5.6).
* **The tracker statement is still planned on every call** (1.9 ms; a generic plan was slower for the in-view cell, section 9.2): splitting it so that the few ids of a quiet tick take a cheap statement is the way.
* **Zombies** keep the chase AI and its lanes of sql/541; **despawn** (600 ticks without a viewer) is unchanged (vanilla's cows never despawn: the prototype rule is kept).
* **Floors now**: in view ~2.5 ms at 2,000 near cows with the fixed cost removed (5.6 today), outside the view 0.4 us per mob (reached), no lane ~25 ms at 2,000 scattered blocks with lanes that end at obstacles
  (48 today), empty tick 0.04-0.07 ms (reached).
