# Pairing deferral for login storms, the locator bar's first pass, and the narrow position table (PERF-PAIRING)

Three pieces of work on the tick of a login storm, in the order the brief gave them.  Short answers first:

1. **Tracker pairing deferral: built, proven, and it does nothing measurable for the 200-join storm** (see "Why the storm does not show it").  A joiner's pairing now waits in a queue (`mc.vpair`)
   under a measured per-tick budget; with one join per tick (what the join entry budget makes of a storm) nothing is ever delayed.  What it does is cut the peak of a *burst* (three joiners in one
   tick: 32 -> 22 ms of tracker work in the joining tick in the database-only test) and it costs nothing when it is idle.  Default on, `dbcraft.pair-budget-ms = off` turns it off.
2. **The cost that did matter was inside the locator bar's first pass for a new player** (3): `mc.wp_cand_state` was inlined by the planner into a join of every player with every player and a hash
   of all of `mc.wp`.  Fixed (same rows, one function): **a joiner's tracker work at 200 players online fell from 24.4-25.1 ms to 11.3-13.1 ms per join tick** (database-only, repeated twice, no
   noise to speak of), `mc.vis_wp_pass` 10.5 -> 5.2 ms per call in the live storm profile, function time of `mc.server_tick` over the storm -16%.  The end-to-end tick figures of the storm
   (worst tick, p99, ticks over 100 ms) **do not separate from the machine's noise** in 3 + 3 alternated runs (below): a 3.5 ms per tick saving on a 35-45 ms tick that varies by +-5 ms between runs.
3. **Narrow position table: not built.**  Inventory, prototype measurement and an exact plan below.  The measured saving is 8 ms per tick at 500 walking players (9.3 ms wide UPDATE against 1.3 ms
   narrow), about 6% of that tick, at the price of a rewrite of 64 SQL files that other agents are editing; the safe variant (a view named `mc.player` over two tables) gives back about a third of the
   gain in the scans of the tick.  Decision: stop at inventory + prototype, as the brief allowed.

Everything here is measured on this machine with 3 other agents running (load 0.6-2.5 during the cells); each number says what it is.  Raw rows: `docs/perf-pairing-results.txt`
(`python3 tools/scoreboard/pairing_report.py`, `--prof TAG` for the phases of the slowest ticks and the function profile).

## 1. Pairing deferral

### What vanilla does (and what that makes of the brief's question)

`PlayerList.placeNewPlayer` calls `ServerLevel.addNewPlayer`, which reaches `ChunkMap.addEntity`: the new player gets a `TrackedEntity`, and `updatePlayers(level.players())` pairs it at once with every
player in range (`TrackedEntity.updatePlayer` -> `ServerEntity.addPairing`: the `add_entity` bundle in both directions, `ServerWaypointManager.addPlayer` for the locator bar).  Vanilla does **not**
spread pairing over ticks: it is one Java call inside the join, microseconds per pair.  So the deferral is a deliberate difference from vanilla's timing (`docs/DIFFERENCES.md` row 63), which is why
it is bounded, measured and only engages over budget.

### What was built (`sql/903`, `905`, `906`, `907`, `908`, `909`; `sql/430` one line)

* `mc.vis_join` (called from the join, `sql/906`) puts the joiner into the unlogged queue `mc.vpair (entity_id, since)`.
* `mc.vis_pair_release` runs first in `mc.refresh_visibility_vis` and lets joiners out of the queue, oldest first: `dbcraft.pair-free` (1) per tick always; more while the moving average of the measured
  ms per released joiner (`mc.vpair_state.ema_ms`: the pair search and bundles of the refresh, the first tracker pass and the locator connections, measured in the ticks that had any) times their number
  fits `dbcraft.pair-budget-ms` (8); everything at once with `off` (the old behaviour exactly).  `dbcraft.pair-tick-ms` (default `off`) holds even the free one back in a tick that has already spent
  that many ms before the pairing (`mc.server_tick` stamps `dbcraft.tick_t0`); `dbcraft.pair-max-wait-ticks` (20) bounds every wait, at least one joiner per tick leaves when the oldest has waited that long.
* A queued joiner is *not paired yet*: `mc.vis_find` leaves it out of the dirty list, the first tracker pass and the locator bar's transmit-state pass; the pair search takes it as nobody's partner;
  `mc.vis_first_tick` skips it; `mc.vis_wp_pass` keeps its transmit state unset and does not write it.  Its **own** join burst (waypoints, entity data, attributes) is produced by the join as before.
  When it leaves the queue, the same tick's refresh pairs it with everybody in range from its state of that moment, then the first tracker pass and the locator bar's new-source pass follow in the same
  tick (the order of an unqueued join).
* A vanilla-equivalent for a pair formed later: the bundle carries the current state once.  Frames that exist only because both sides were paired in the same tick are absent for a joiner paired a tick
  after another joiner: the repeat of the first tracker pass's entity data / attributes, and the zero move of the tracker's first body (tickCount 0).  `tests/sql/991` states exactly this.

### Proof (`tests/sql/991_pair_defer.sql`, 22 checks)

Random worlds of returning players (80 online, joiners 3-5 per tick, view distance 10, spread over 300 blocks):

* budget big enough or off: the same `mc.visible`, `mc.wp` and **the same bytes per connection on every tick, in order** as the old behaviour;
* over budget: the queue has the length the rules say tick by tick, a queued joiner is in no pair and no waypoint connection, the queue is empty after N ticks;
* then: the same `mc.visible`, the same `mc.wp`, and every frame of the run (every pairing bundle and locator packet, byte for byte) occurs as often as in the undeferred run except the two
  explained repeats;
* three mutations (a deferred joiner not left out of `mc.vis_find`, of the pair search's partners, of the locator pass) are each detected.  The test also found a real bug in the first version
  (`mc.vis_first_tick` processed every player with the flag, not only the released ones: a queued joiner's first pass was consumed with no viewers).
* `tests/sql/900`, `981`, `990`, `1000`, `465`, `469` unchanged and green.  (`1000_wp_dirty`: one of its mutation checks was flaky with random uuids for the test's joiners, found while running it
  three times; they are deterministic now.)

### Why the storm does not show it

`net.join_gate` and the join entry budget (`dbcraft.join-entry-budget-ms` 10, free 1) already make a 200-join storm one joiner per tick: `mc.vpair_state` after the cells says it, e.g. over
a 200-join storm 220 released (200 + the 20 online bots), **max queue depth 1-4**, "deferred ticks" (the queue was not empty after the release) 0-193 depending on the run.  A pairing of 12-25 ms in
every tick cannot be moved to "another tick": every tick has one.  The measured average cost of a pairing (`ema_ms`) was 21-25 ms before the locator fix and 13-15 after, always above the 8 ms
budget, so the free slot is the only one used.  Deferral can only shave a *coincidence*, a tick with two or more pairings (a joiner paired while another's configuration step runs is not the
same thing: that is the process phase).  Measured in the database alone, 200 online, three joiners in one tick (`tools/scoreboard/pairing_join_bench.sql` family, two bursts each, ms of
`mc.refresh_visibility` + `mc.vis_step`; other tick work is not in it):

| | joining tick | the next ticks |
|---|---|---|
| budget off (all three at once) | 31.8 and 22.5 | 8.0, 1.2 / 6.8, 1.4 |
| budget 8, average 15 ms (one a tick) | 22.5 and 17.2 | 19.5, 15.5 / 17.5, 12.9 |

(The joining tick still carries three `on_join` + `vis_join` + `vis_wp_join` of about 7 ms and the three joiners' own waypoint lists: those are the join, not the pairing.)  The peak of a
burst falls by a third at three joiners and by more with more; the ticks after it carry what was taken out.  `dbcraft.pair-tick-ms = 40` (hold the free one back too in a heavy tick) was run
twice in the storm (`b40-r0/r1`): worst tick 97 / 98, 0 ticks over 100 ms, which is within the spread of every other cell: **no measurable effect, left off**.

### The storm, before and after (storm2, 200 joins into 20 online players, view distance 10, Rust gateway, own cluster, `tools/scoreboard/pairing_cell.sh`)

Alternated cells, the tree before (`299673a`, own cluster 56840, `git archive`) and this tree (cluster 56830), both driven by this tree's harness, load 1.8-2.5 (other agents):

| | before: 3 runs | after: 3 runs |
|---|---|---|
| worst tick, ms | 84.5, 82.6, 71.9 | 96.0, 105.4, 78.3 |
| tick p99, ms | 68.8, 79.0, 68.5 | 82.8, 74.6, 61.8 |
| ticks over 100 ms | 0, 0, 0 | 0, 1, 0 |
| ticks over 50 ms (of ~320) | 50, 105, 39 | 46, 28, 32 |
| mean tick, ms | 34.3, 38.9, 34.4 | 35.6, 34.7, 34.7 |
| tick backend CPU, ms per tick | 40.5, 44.6, 40.1 | 40.3, 41.1, 40.7 |
| online chat p50 / p99 during the storm, ms | 29 / 94, 36 / 97, 31 / 101 | 40 / 114, 27 / 124, 24 / 87 |
| all joined with all chunks, s | 16.6, 17.9, 16.3 | 17.1, 16.3, 16.3 |

**The ranges overlap in every row.**  Worst tick and ticks over 100 ms are as noisy as in `PERF-STORM-MEASURED.md` (one slow tick decides them); the expected effect (3.5 ms of a 40 ms tick) is below the
run to run spread of the mean (34.3-38.9 in one tree).  Earlier cells of the same session (a 200-join storm on the pre-fix tree, deferral on / off, load 0.6-1.6) are in the results file: worst
tick 94-124 ms, 0-2 ticks over 100 ms, 27-116 ticks over 50 ms, mean 33-45 ms, with the same overlap.  Do not read an effect into these.

What is measurable is the work.  The same storm with `track_functions = 'pl'` (one profile run each, `base-prof` before at load 0.7, `w-prof` after at 1.7; function time includes nested calls):

| function (200 joins, ~330 ticks) | before, ms | after, ms |
|---|---|---|
| `mc.server_tick` | 14,216 | 11,950 |
| `mc.tick_core` | 5,219 | 4,061 |
| `mc.vis_step` | 3,154 | 2,069 |
| `mc.vis_wp_pass` (195-197 calls) | 2,069 (10.5 per call) | 1,015 (5.2 per call; self 1,944 -> 636) |
| `mc.wp_cand_state` (was inlined: not a function in the profile) | | 273 |
| `mc.refresh_visibility_vis` | 1,171 | 1,176 |
| `mc.vis_first_tick` | 281 | 299 |
| `mc.pairing_bundle` | 256 | 249 |
| worst tick of the run | 119.6 ms | 80.1 ms |

And the database-only measure of one joiner's tracker work (`tools/scoreboard/pairing_join_bench.sql`: N returning players online, 25 joiners one per tick, ms per tick of `mc.refresh_visibility` +
`mc.vis_step`, the first five joiners are warm-up), on the tree before (database `pp_base`) and after, two runs each (default settings, so the queue is idle):

| online | before: refresh + vis_step | after |
|---|---|---|
| 50 | 6.08 / 7.30 (vis_step median 4.1 / 5.0) | 5.33 / 6.97 (3.8 / 4.8) |
| 200 | **24.44 / 25.05** (vis_step median 20.6 / 19.6, worst tick 27.5 / 39.2) | **13.11 / 11.30** (vis_step median 8.8 / 7.8, worst tick 15.8 / 13.3) |

## 2. The locator bar's first pass for a new player (what the profile found)

At 200 players online `mc.vis_step` of a joining tick took 20 ms, 14 of them in `mc.vis_wp_pass(.., 2, ..)`: the entity phase that announces a new source to every receiver.  `auto_explain`
(nested statements, analyze) of the statement showed the cause: `mc.wp_cand_state` is a `language sql` function, so the planner inlined it into the pass as

```
mc.player r join mc.player s on s.entity_id <> r.entity_id ...  Join Filter: (r = ANY(sset) OR s = ANY(sset))    (41,006 pairs tested, 40,602 removed)
left join mc.wp w ... Hash Right/Left Join over Seq Scan on wp w (actual rows 40,804, 7 ms to hash)
```

for the 404 rows that matter (the new source's pairs).  The planner thinks the churned unlogged `mc.wp` has 1,940 rows (it has 40,804), so it hashed it.  Now (`sql/908`): plpgsql with a generic plan, the two
halves "receiver changed" and "source changed, receiver not" each from the index on `mc.player`, and the connection probed by primary key through `left join lateral (... limit 1)`
(`limit 1` is what keeps the planner from pulling the subquery up into the hash join again).  The statement went 21.9 -> 3.2 ms in the explain; `tests/sql/1000_wp_dirty.sql` (the dirty-driven pass
against the all-pairs reference on random walks, joins, leaves, crouching, spectators, hidden heads, view distance changes: same packets, rows and remembered state) passes, with its two mutation
checks of this function rewritten for the new text (a changed receiver only / a changed source only are both detected).

## 3. Narrow position table: inventory, prototype, plan (not built)

**What a mover costs now.**  `mc.apply_player_moves` (sql/431) writes, per mover, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, vis_dirty, vis_ocx, vis_ocz, last_move_tick, yaw_prev of the
115-column `mc.player` row (a wide row is rewritten whole by every UPDATE).  `tools/scoreboard/pos_proto_bench.sh` (own transactions like a tick, a vacuum every 20 statements, the statement shape of
the fast path with `unnest`, scratch database, 200 statements):

| movers per tick | wide `mc.player` UPDATE | narrow UNLOGGED table (fillfactor 50, 16 columns, one primary key) | saving |
|---|---|---|---|
| 500 | 18.7 us per mover = **9.34 ms** per tick | 2.6 us = **1.29 ms** | 8.0 ms |
| 100 | 18.5 us = 1.85 ms | 3.7 us = 0.37 ms | 1.5 ms |
| 25 | 30.9 us = 0.77 ms | 10.0 us = 0.25 ms (fixed statement cost dominates) | 0.5 ms |

(An earlier version of the bench ran everything in one transaction, where no page is ever pruned: 50-58 us against 14-16 us; that is not the server's situation and was dropped.)  The heap of the
narrow table is a quarter of the size.  The tracker already keeps its hottest state (the position and angles viewers were told) in such a table, `mc.vtrk`.

**Inventory (grep, this tree).**

* Writers of the position columns (`chunk_x = ...`): `sql/330`, `340`, `382` (batched, opt-in), `431` (the live fast and general paths), `434` (shard, opt-in), `456` (the old live-state prototype, unused), `461`
  (`mc.on_join`), `813` (`/tp`, the commands agent), `836` (respawn, the survival agent); `last_move_tick` is written only in `431` and the tracker (`903`, `905`, `907`, `908`); `vis_dirty` in 19 files.
* Readers: `mc.player` is mentioned in **64 SQL files and 51 test files**; `x`, `y`, `z` are read in about **500 expressions** (`p.x`, `.z` ... in 75-103 files, commands, survival, containers, dynamics, entity code, chunk
  streaming, the locator bar, the tracker) and `chunk_x` / `chunk_z` in 34 files and 39 tests; two partial indexes of `mc.player` (`player_online_chunk_idx` on `(chunk_x, chunk_z)`) serve the neighbourhood search.
* Other agents are editing 12 of these files right now (commands 813-815, mining 840-849, dynamics 880-889, light 21x-23x).

**The plan, if it is done (decided: not now).**  It must not change a reader, so the table cannot simply move columns:
1. Rename the table `mc.player` to `mc.player_base` (without the 13 hot columns), add `mc.player_pos (entity_id primary key, <the 13 columns>, vis_x, vis_z, wp_b*, wp_c*)` UNLOGGED, fillfactor 50, no index on a
   changing column (chunk indexes are the one exception: HOT holds while the chunk does not change), made by the join trigger like `mc.vtrk`, removed on leave; `mc.player_base` keeps the last snapshot of
   the position (written every N ticks, on leave, on teleport, at death: the durable position, as `sql/456` sketched).
2. A view `mc.player` = base join pos (a left join: offline players have no pos row) with the same 115 columns in the same order, `INSTEAD OF UPDATE / INSERT / DELETE` triggers that route to the two tables,
   so that every reader and every rare writer (commands, survival, respawn, containers) keeps working untouched.  The tests' `insert into mc.player (...) values (...)` and `session_replication_role` tricks go
   through the same triggers.
3. The hot writers (`431`, `907`, `909`, `908`) write `mc.player_pos` directly; the tick's scans that read both (`mc.vis_find`, the locator pass's `pl`, `survival_entities`, `moves_idle`) are rewritten to
   read what they need from the narrow table first.
4. Proof: the full suite plus a differential test running random scripts (moves, teleports, joins, leaves, respawns, `/tp`, kicks) against the old table and the new view and comparing positions,
   `mc.visible`, `mc.wp`, every packet and every kick, tick by tick, as `tests/sql/990` does for the visibility pass.

**Why not now.**  (a) The gain is the 8 ms at 500 movers above (6% of that tick, less at 100-200 walkers: 1.5-3 ms), and the view makes every read of `mc.player` a join: the tick reads it 8-10 times
(`vis_find`, `survival_entities`, `tick_core`'s count, the locator `pl`, ...), at 500 rows each, 1-2 us a row more for the join: **2-4 ms back**, so the net gain is 4-6 ms at 500 movers.  (b) A trigger-routed view
is slower for the writes that are not rewritten, and a partially rewritten tree is exactly the state in which another agent's `update mc.player set x = ...` silently takes the slow trigger path.
(c) Every test file that sets a position directly (79 of them mention x) has to keep its meaning under the view.  It is a day of work for 4-6 ms, to be done when the tick has nothing larger left; the
larger items are the chunk path (`deliver_ready_chunks` 7-9 ms a tick, `docs/PERF-STORM-MEASURED.md`), the join's `h_config` (20 ms), and the 60-100 ms ticks of a 500-player crowd.

## What remains of the storm's tail (not changed here)

* The join tick is still `net.h_config` 15 ms per joiner in the last profile (`net.play_begin` 13.9: `hook_join_info` 6.4 of which `mc.on_join` 2.3 and `mc.vis_join` 3.5 with `mc.vis_wp_join` 2.8 inside it, `hook_chunks` 3.2,
  `play_entry_packets` 2.2) + the tracker's 11-13 ms at 200 players + `deliver_ready_chunks` 6.9 ms self per tick: the per-tick base the worst ticks are made of.  The worst ticks (80-125 ms) are join
  ticks that also have a second configuration step, a chunk burst or a long `refresh_visibility` (13-20 ms in 3 of the 8 slowest ticks of `w-prof`, against 3.9 ms on average: not explained, the next thing to
  trace with `auto_explain` on a storm).
* Two small ones seen: `mc.vis_wp_join` inserts one `mc.wp` row per source for the joiner (2.8 ms at 200 players), and the first tracker pass (`mc.vis_first_tick`, 1.5 ms per joiner) builds the attribute
  list per pair; neither was touched.

## Reproduce

```
tools/pg-dev.sh start                                      # own cluster: DBCRAFT_PGDATA=/dev/shm/x DBCRAFT_PGPORT=568xx
tests/sql/prun.sh pair_defer                                # the differential test (also 900 / 981 / 990 / wp_dirty)
CAP_DIR=/dev/shm/pp_cap CAP_PORT=56830 tools/scoreboard/cenv_capacity tests/e2e/setup.sh        # the storm cluster (gateway/build.sh first)
CAP_DIR=/dev/shm/pp_cap CAP_PORT=56830 tools/scoreboard/pairing_cell.sh TAG 200                  # one cell -> docs/perf-pairing-results.txt
SCORE_STORM_PROF=1 tools/scoreboard/pairing_cell.sh TAG-prof 200 ; python3 tools/scoreboard/pairing_report.py --prof TAG-prof
sed "s/:n;/200;/; s/:j;/25;/; s/:side/960/; s/:bud/8/" tools/scoreboard/pairing_join_bench.sql | psql -X -q SCRATCHDB    # the joiner cost, database only (also on an older tree)
tools/scoreboard/pos_proto_bench.sh 500 200                # the narrow position table prototype (scratch database: it empties mc.player)
```
