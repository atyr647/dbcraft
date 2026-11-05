# Login storms against the Rust gateway: what the stall really was, and what it costs now (STORM)

**Round 2 (full tree, locator bar, urgent lane) is at the end of this file.**

**Short answer (round 1).**  The login-storm stall was not mainly the login: at the scoreboard's view distance (10) with an explored world **every joiner was sent its whole square of 529 chunks (3.7 MB) inside its own join tick**,
about 80 ms of database time per joiner on top of about 15-20 ms for the join itself.  `docs/PERF-JOIN.md` and `docs/PERF-JOINBUDGET.md` were measured at view distance 2 (49 chunks), where that cost does not show.
Now a joiner gets the nearest 49 chunks in its join burst and the rest over the following ticks, at most one (or, when the first was cheap, two) logins enter play per tick, and the chunk stream takes what is left of a tick budget.
**Measured on a machine that was never quiet (load average 7-25 on 4 cores, other agents' servers and test suites): the worst tick of a 50-join storm fell about 3 times (median of three, interleaved), the p99 of the chat round trip of players who were already online
about 5 times and the worst one about 5 times; for 200 joins the in-database CPU time of the worst tick fell from 4-8 seconds to 0.23-0.25 s.**
**What is NOT shown: a worst tick at or below 55-60 ms.  It is not reached** (CPU time of the worst tick is about 140 ms at 50 joins into 20 players, 230-250 ms at 200 joins into 200 players, see "What is still a loss"), and the **200-join runs with real clients could not be completed
on this machine in the final session** (one overloaded repetition only, no vanilla, see "Measurements").  Do not quote a ratio to vanilla for 200 joins from this file without reading that section.

## What "vanilla's worst tick" was (a correction to docs/SCOREBOARD.md)

The first scoreboard compared dbcraft's **worst single tick** (`max(ms_total)` of its tick log) with vanilla's **worst 100-tick average** (`mspt_worst_window_avg` of `/tick query`, polled every second): 444 ms and 5,726 ms against 44.7 and 53.5 ms.
A 100-tick average hides a stall of several hundred ms (one 500 ms tick adds 5 ms to the average).  `tools/scoreboard/run.py storm2` measures what a player feels instead, on both servers the same way: **players who are already online** (12 idle bots and 8 chat probes, in play and settled) chat once a second per probe
(Vanilla kicks a player for more than about one chat message a second, so eight probes give eight samples a second) and the round trip of every message is logged with its time; the storm (50 or 200 clients connecting within 1 s) is
cut out of that log.  For vanilla the tick figures are the worst 100-tick window's p99 and average (`/tick query` twice a second), for dbcraft the real per-tick maximum and p99 of `mc.server_tick_log`.
**Vanilla is not smooth either**: in the first session (load 3.6-11) a 50-join storm gave a worst window p99 of 200-246 ms (a 155 ms GC pause among them) and chat round trips up to 695-850 ms for the players online; with 200 joins the worst window p99 was 407 and 1,281 ms and the online players waited up to **2.4 and 4.3 s**
for a chat echo.  Its window average (the old scoreboard's number) was 65 ms for 50 and 85-130 ms for 200 joins, not 45 and 54.  Its joiners are slow instead: 45-49 s (50 joins) and 49-57 s (200) until everybody is in with all chunks.

## Where the time went (profile, `tests/bench/join/storm.sql` harness, 100 players online, 20 joiners in one tick, view distance 10, chunks cached)

| Per join (ms of database time, `pg_stat_user_functions`, totals / joins) | before | after |
|---|---|---|
| `net.send_chunks` in all (of it `net.hook_chunks`: reading the cached packets, checking which chunks exist, recording the rest as wanted) | 80.8 (hook_chunks 29.4) | 8.8 for 49 chunks (hook_chunks 7.0) |
| `mc.on_join` + `net.hook_join_info` | 4.8 | 3.1 |
| the rest of the entry (entry burst, tab list, config burst, login checks) | about 4 | about 4 |
| **whole process phase per join** | **98 (1,958 ms for 20 joiners in one tick)** | **about 17 (423 ms for 20)** |
| 100 joiners in one tick | 23.2 s | 2.0 s |

A tick that delivers 600 chunks (the old global cap) costs 13-25 ms in `mc.deliver_ready_chunks` + move to the outbox and 10 ms more in the gateway's drain; the old delivery query ranked every wanted row of every connection every tick.

## What changed (all client-visible bytes per joiner unchanged except where stated)

* **`net.hook_chunks` (sql/430_chunk_queue.sql, edited in place)**: only the nearest `dbcraft.join-chunks-inline` chunks (default **49**, the whole square at view distance 2, so every recorded-vanilla comparison, which runs at view distance 2, is unchanged) are returned for the join burst; the rest of the square is recorded
  in `mc.chunk_wanted` (a plain set-based insert: 1.5 ms against 5 ms through `mc.want_chunks`) and sent by `mc.deliver_ready_chunks`.  0 = the old behaviour.  **Deviation from the old bytes, deliberate:** above view distance 3 the chunk packets arrive in more than one `chunk_batch_start..finished` group (first group 49 chunks), in later ticks, interleaved with whatever else
  is sent in those ticks.  Vanilla's own chunk sender also sends many small batches; the chunk packets and their nearest-first order are identical (`tests/sql/920`: 121 chunks, md5 of every packet in order, with and without the split).
* **`mc.deliver_ready_chunks` (sql/791_join_chunk_budget.sql, edited in place)**: rewritten so its cost depends on the caps, not on the backlog (a storm of 200 leaves 96,000 wanted rows): per connection an index scan (new index `(conn_id, dist, cx, cz)`) with `LIMIT`, a loose index scan for the connections that have rows,
  rows of departed connections dropped, rows outside a moved client's square dropped when its view moved (`mc.chunk_wanted_view`), the cached packet read by a join instead of the plpgsql function.  Both caps (`dbcraft.chunk-batch-max` 64 per connection, `dbcraft.chunk-budget-per-tick` 600 in all) apply in inline mode too (they were async-only).
  **`dbcraft.tick-budget-ms` (40)**: the shared cap shrinks with the time the tick has already used (`net.process_fast` records its start in a transaction-local setting): a tick that spent the budget sends 40% of the cap, a tick without joins all of it; not scaled when no start was recorded (tests, the batched tick), `off` = the cap alone.
  Same frames, same order per connection (`tests/sql/437` and `432` compare it with the previous bodies).
* **Join entry budget (`net.process_fast`, sql/430_tick_perf.sql, edited in place; settings in sql/920_join_stage_budget.sql)**: the packet that makes a connection enter play (`finish_configuration`) is the expensive step.  Once a tick has spent `dbcraft.join-entry-budget-ms` (**10**; `off` = never) in the function, further entries
  are put back into `net.inbox` with their sequence numbers (and everything behind them from the same connection) and run in the next tick, oldest connection first; `dbcraft.join-entry-free` (1) entries per tick always run.  A connection that waited past `dbcraft.join-max-wait-s` is let in regardless, **at most 3 per tick**
  (without that cap a queue whose members all hit the limit together, as on an overloaded machine, was let in as one tick of 2-8 s; found in the last measurements).  The client is waiting for its `login` packet and sends nothing, so nothing is lost; the joiner's bytes are identical to the unbudgeted run (`tests/sql/920`: md5 of six burst streams, entity ids and tab list included).
  The login gate of sql/790 (AIMD on the hello) stays as it was: with the entry budget it settles at one hello per tick.
* **Harness (`tools/scoreboard/`)**: `run.py storm2` (a storm into a server with players online, with the chat probes), `loadgen.py --probes/--probe-interval/rtt log with time`, `dbcraft.sh` kills only its own gateway pid (it used `pkill -f gateway/target/dbcraft-gateway`, which kills every other agent's gateway on a shared machine), `vanilla.sh` takes the jar and the heap from `SCORE_JAR`/`SCORE_HEAP`.

## Measurements

Machine: 4 cores shared with about 8 other agents; **load average 7-25 during every number below** (the first session 3.6-17).  Wall times are inflated by that, CPU times less.  Own PostgreSQL cluster in `/dev/shm`, Rust gateway, view distance 10, flat world pre-generated on both servers, 20 players online (12 bots + 8 probes), storm of N clients in 1 s.

### Real clients, 50 joins (post-restart session, interleaved vanilla / old dbcraft / new dbcraft, 3 repetitions, load 7-18, machine busy 95-100%)

| | vanilla | dbcraft before | dbcraft after |
|---|---|---|---|
| worst tick (dbcraft: max tick; vanilla: worst 100-tick window p99), ms | 1,409 [244-2,269] | 854 [500-2,055] | **265 [148-368]** |
| dbcraft p99 tick / vanilla median of window p99, ms | 301 [136-421] | 772 [486-1,395] | **220 [89-303]** |
| ticks over 100 ms | | 31 [19-31] | 51 [1-58] |
| online players: chat round trip during the storm p50 / p99 / max, ms | 548 / 5,064 / 5,085 | 556 / 2,005 / 2,209 | **208 / 417 / 437** |
| time until all joined with all chunks, s | 60.8 [43.8-68.3] | 20.0 [9.1-22.0] | 16.9 [5.5-22.2] |
| runs in which connections were dropped (gateway read timeout under CPU starvation) | 0 of 3 | 2 of 3 | 1 of 3 |

Ranges are min-max of 3; the spread is as large as the effect for "ticks over 100" and "time until all joined" (the load changed by a factor 2.5 between repetitions).  The sorted p50 of vanilla is a median of few samples (68 to 280 per run).

First session (before the restart; the raw file was lost with `/dev/shm`, numbers copied from the console output; load 3.6-17), 2-3 repetitions: **50 joins**: vanilla worst window p99 223 [200-246], window average 65, chat during p50 27 / p99 462 / max 773, all in 47 s;
dbcraft before: worst tick 340 [206-573], chat p50 156 / p99 474 / max 525, all in 6.5 s; dbcraft with the chunk split and an early version of the budgets: worst tick 82 and 84, no tick over 100, chat p50 108-110 / p99 192-217 / max 199-221, all in 3.5 s.
**200 joins**: vanilla worst window p99 407 and 1,281, chat p50 50 / 178, p99 2,426 / 4,285 (max 4.3 s), all in 49 and 57 s; dbcraft before: worst tick 298-925, chat p50 217-444, p99 657-2,023, all in 19-26 s;
dbcraft with the entry budget (10 ms) and static caps: worst tick 535 and 197, chat p50 184 / 155, p99 969 / 384, all in 26 and 21 s; with the time-scaled cap (floor 15%, an intermediate version): worst tick 132, p99 111, chat p50 93, p99 216, max 249, but all in 37 s (the cap shrank too far; the shipped floor is 40%) and a second repetition hit a 7.6 s stall of the whole machine.
**Final code, 200 joins, real clients: one repetition at load 20-25 (the only one that ran; vanilla did not start in 4 of 4 attempts within its 120 s limit, so there is no vanilla number from this session)**: before: worst tick 13.4 s, 109 of 200 joiners and the 12 online bots lost to the gateway's 30 s read timeout, chat p99 for the online probes above 10 s;
after: worst tick 1.27 s, p99 765 ms, 51 of 200 joiners lost (same cause: the load generator and the server were starved of CPU), chat p50 434 / p99 1,980 / max 2,352 ms.  An improvement of the same direction, but **an overloaded run, not a result**: nobody finished within the 240 s limit on either version.

### Paced in-database storm, CPU time per tick (`tests/bench/joinbudget`, view distance 10, 20% of the online players walking, old and new code interleaved; on-CPU time, so load matters less; the first 8 ticks, which include the harness's own setup, excluded)

| scenario | | worst tick CPU ms | p99 CPU ms | median CPU ms | ticks over 100 ms CPU |
|---|---|---|---|---|---|
| 50 joins into 20 online, 3 reps | before | 276 / 243 / 225 | same (about 100 ticks) | 71 / 76 / 38 | 15 / 16 / 20 |
| | **after** | **142 / 144 / 139** | 116 / 121 / 120 | **26 / 32 / 27** | **2 / 2 / 2** |
| 200 joins into 200 online, 2-3 reps | before | 4,109 / 6,952 / 8,070 | 3,870 / 4,792 / - | 40 / 183 / 77 | 21 / 19 / 15 |
| | **after** (final code) | **229 / 251** | **174 / 168** | 49 / 44 | 51 / 47 of about 1,000 |

The remaining ticks over 100 ms at 200 online are, for the most part, the steady cost of 200 players of which 40 walk (every 20th tick about 100 ms CPU, also after the storm; `mc.apply_player_moves`, another track's) and, during the storm, the tick with the entry plus 240 chunks.
The same harness with the earlier overdue rule (everything past 20 s let in at once) showed ticks of 1.6 and 2.1 s CPU and 14-16 ticks over 100 ms: that is the flood the cap of 3 per tick removed.
**All-in time in this harness: 62 and 72 simulated seconds (after) against 34-40 (before)**.  The harness clock advances by the real duration of every tick, and the ticks averaged 144-168 ms of wall time on this loaded machine for 56-59 ms of CPU, so 430 ticks needed
(200 entries at one per tick, 106,000 chunks at 240-600 per tick) would take about 430 x 55 ms = 24 s on a machine that keeps the 20 Hz tick; **that is an estimate, not a measurement**, and under the load of this session the join of 200 players took longer than before and about as long as vanilla's 49-57 s.

## What did not work or was changed after measuring

* **Spreading only the hello (the existing AIMD login gate)**: the cost sits in the entry, three ticks after the hello, so the controller (which looks at the previous tick) oscillated: ticks alternated between 10 and 200-570 ms with clients arriving in waves.
* **A static global chunk cap of 600 per tick** is 13-25 ms of delivery plus 10 ms of gateway drain: more than the whole tick target.  Scaling it with the time already spent (`dbcraft.tick-budget-ms`) works, but a floor of 15-25% made the 200-join chunk stream take 37 s instead of 22 s; 40% is the compromise.
* **Writing the remaining 480 chunk rows through `mc.want_chunks`** (unnest, `ON CONFLICT DO UPDATE`): 5 ms per join; a plain `INSERT ... SELECT` 1.5 ms.
* **The first overdue rule** (a connection past its maximum wait is never held): under overload everything crosses the limit together; 100+ entries in one tick (2 s CPU).  Now at most 3 per tick.
* **Ranking all wanted rows each tick** (the old `mc.deliver_ready_chunks`) cannot work with the backlog a spread-out join creates: rewritten.
* Not tried: a per-connection chunk cursor instead of 480 rows per joiner (it would remove 1.5 ms per join and the delete of delivered rows); `mc.on_join`'s O(online players) fan-out (2.5 ms per join at 100 online, more at 200); the unattributed 100 ms tick every 20th tick at 200 online (movement bookkeeping).

## What is still a loss or open

* **Worst tick <= 55-60 ms is not reached.**  50 joins into 20 players: CPU 140 ms worst (the tick in which two entries or an entry and the 20th-tick work coincide), 25-30 ms median; 200 into 200: 230-250 ms worst, 45-50 ms median, p99 170 ms.  Vanilla's own figure is not 55 ms either (see the correction above): its worst window p99 was 200-246 ms (50 joins) and 407-1,281 ms (200),
  its online players saw up to 0.7-0.85 s and 2.4-4.3 s.  dbcraft's chat round trip for the online players during the storm is better in the tail (p99 417 against 5,064 ms in the loaded session; 192-217 against 462 in the quieter one) but **worse in the median in the quiet session** (108-208 ms against 27 ms at 50 joins):
  a chat message waits for the next tick (20 Hz) and the tick is 30-60 ms long during a storm.
* **200 joins with the final code and real clients, and the vanilla comparison for them, are not measured on a usable machine** (see above).  The time to all joined with all chunks at 200 joins is expected between 20 and 40 s (not measured).
* Under CPU starvation (load 15-25) the gateway's 30 s read timeout dropped all connections in some repetitions of both the old and the new code (`gateway_failed_*.log`, "dropped: read timeout (no bytes)"); this was seen before this work too (a 50-join baseline run lost its 12 online bots).
* The gate of sql/790 still has its own deadline floor, which can release a queue in a burst.
* `tests/e2e` (fixed ports) was not run.

## Tests

`tests/sql/920_join_stage_budget.sql` (29 checks; the whole suite: 65 files, 2,294 checks, `tools/check_overrides.py`, `tools/check_inlining.sh`, `tools/check_fresh_migration.sh` green): budget off = all six enter in one tick; exhausted budget = the free entry only, the others back in `net.inbox` in order, one more per tick, all six in after nine ticks, and **their join bursts byte for byte the same as without the budget**; two free entries; a connection past its wait is let in, at most 3 overdue per tick; what a held-back connection sent behind its entry packet waits with it;
121 chunks at view distance 4 in the same nearest-first order with `join-chunks-inline` 0 and 49 (first batch 49); the delivery step with a backlog (shared cap round-robin, view moved, connection gone).  `tests/sql/791` and `430` unchanged except that `dbcraft.tick-budget-ms` is set `off` where a fixed cap is counted.

## Round 2: the storm on the full tree (visibility tracker, survival, containers, dynamics merged)

The final scoreboard campaign (`docs/SCOREBOARD.md`, quiet machine) showed the tail still lost: 200 joins into 20 online, worst tick 948 against 545 ms and p99 265 against 120 ms; 50 joins, online chat p50 146 against 28 ms.  `main` was merged and both cells reproduced with `tools/scoreboard/run.py storm2` (own cluster in `/dev/shm`, Rust gateway, view distance 10).
**The machine was shared with other agents during every number below (load average 1.6-5.3 on 4 cores); old and new code were alternated inside each repetition, three repetitions, ranges are min-max.  Vanilla ran once per size in this session (it did not start in time at load above 6 and the load gate waits), so its numbers are one repetition each, next to the quiet-machine campaign figures.**

**Where a join tick went** (`pg_stat_user_functions` over a whole 200-join run, then `auto_explain` per slow statement, then `jbench` with 100 players online and `track_functions = 'pl'`):

| | before | what it was |
|---|---|---|
| the worst tick of the storm, **1.2-1.6 s**, once, when the 121st player joins | 14,280 UNTRACK packets (120 x 119 locator-bar connections) in one tick | `dbcraft.locator-bar-max-players` (120) switches the bar off; the pass ends every connection at once.  Each waypoint packet cost 130 us in `mc.wp_body` (five PL/pgSQL VarInt calls and a text round trip for the UUID) plus **50 us in `proto.frame` because the packet id 141 takes its slow branch**: `proto.varint_slow` had a `FROM` subselect and could not be inlined (it is also the path of ids 128-143: `teleport_entity`, `update_attributes`, `update_advancements`, `update_tags`, `waypoint`, and of every negative coordinate) |
| every join tick of every player count | `mc.vis_wp_pass` looked at all N x N pairs in the entity phase (52 ms at 100 players) to find the one new player | the locator bar |
| `net.play_begin` 35-42 ms per join | `mc.vis_wp_join` 19 ms, `net.hook_chunks` 15 ms (529 single index probes for "which chunks exist" 8 ms, 49 chunk packets 3 ms, 480 wanted rows 4 ms), `mc.on_join` 5 ms | |
| 16-60 ms of every 4th tick | `mc.dyn_rt_build` (4 chunks per run at 16 ms each, the world-dynamics track's random-tick lists) for the chunks the joiners bring | |
| 5-17 ms per join | encoding the chunk packet of every chunk on its first send (7,000 chunks in the run) | |

**Changes.**  `proto.varint_slow` is an inlinable expression (sql/315, same bytes: 400,000 random and edge ints compared in `tests/sql/920`); `mc.wp_body` is built from inlinable pieces (130 -> 3 us, same bytes); a waypoint frame costs 50 -> 5 us; `mc.vis_wp_pass` looks at the pairs of which one side's transmit state changed in the entity phase (52 -> 12 ms at 100 players; random states compared with the previous pass, same packets, rows and remembered states);
with the bar off it takes the rows from the primary key in slices of `dbcraft.locator-bar-untrack-slice` (1500 per tick, byte for byte the packets of the old all-at-once pass, `tests/sql/920`) and drops the rows of players that left; the per-row `mc.prop_int('view-distance')` of the pass is read once;
`net.hook_chunks` reads the existing chunks with one range scan per column (8 -> 1 ms); the chunk generator encodes the packets of the chunks it makes (`mc.generate_pending`), so the tick of the first player who is sent a chunk no longer does (the scoreboard's `storm2` does the same after its pre-generation: `SCORE_COLD_CACHE=1` leaves it to the first player);
`mc.dyn_random_ticks` stops building chunk lists after the first one once the tick has used 60% of `dbcraft.tick-budget-ms` (the rest stays queued for the next run);
**the gateway runs the urgent chat lane before a late tick starts** (`gateway/src/gateway.rs`): the lane used to be skipped whenever the next tick was due within its reserve, and with ticks longer than 50 ms the next tick is always overdue, so chat during a storm waited for the whole tick behind it and then for the next one.
Per join, 20 joiners into 100 co-located players in one tick (a worst case for pairing), ms of database time: whole tick per joiner 83 -> 44, `net.play_begin` 42 -> 26 -> 15 (after the later steps), `mc.vis_wp_join` 19 -> 7 -> 1.7.

**Result** (view distance 10, 20 players online, N clients in 1 s; dbcraft before = the merged tree, old gateway, cold chunk cache; after = this branch):

| | vanilla (1 rep) | dbcraft before | dbcraft after |
|---|---|---|---|
| **200 joins**: worst tick, ms | 1,571 (worst window p99; campaign 545) | 899 [844-1,014] | **257 [239-265]** |
| tick p99, ms | 340 (campaign 120) | 261 [250-295] | **205 [196-208]** |
| ticks over 100 ms | | 129 [118-166] | 66 [64-98] |
| online chat during the storm p50 / p99 / max, ms | 302 / 6,034 / 6,038 (campaign 182 / 2,408) | 205 / 459 / 472 [1,107] | **64 / 180 / 245** |
| all joined with all chunks, s | 58.8 (campaign 51.8) | 41.4 [39.2-44.6] | **34.7 [34.4-35.9]** |
| **50 joins**: worst tick, ms | 358 | 180 [156-255] | **138 [127-214]** |
| tick p99, ms | 113 | 170 [154-172] | **133 [125-205]** |
| ticks over 100 ms | | 25 [22-26] | 13 [11-27] |
| online chat during the storm p50 / p99 / max, ms | 34.5 / 1,127 / 1,295 | 153 / 295 / 305 | **53 / 129 / 130** |
| all joined with all chunks, s | 47.4 | 8.3 | **8.0** |

**Targets and what is still a loss.**  Worst tick at 200 joins below vanilla's 545 ms of the campaign: **met** (257); **not** at 100 ms.  Tick p99 at 200 joins **205 ms against vanilla's 120: not met** (a join tick, entry plus the tracker's pairing, wp pass, first sync and the dynamics, is 80-100 ms of database time at 40-60 players, and one join per tick is
what it takes to finish 200 joins inside the 20 s wait; a tick over 100 ms is nearly every tick of the storm).  Chat p50 at 50 joins **53 ms against 34.5 (target 40): not met**, 3 times better than before; what is left is the length of the storm's ticks, not the lane (a chat that arrives mid-tick waits for the rest of it, the single-threaded gateway cannot read while the database runs the tick).
All joined before vanilla: met at both sizes.
**Not done: deferring the tracker's pairing and first-sync work of a new joiner to later ticks in slices.**  With one join per tick the sum of entry and tracker work per tick does not change by moving the tracker's half one tick later; it only lowers the worst tick if joins are also admitted every second tick (10 per second: 200 joins in 20 s, the wait limit),
and it moves the pairing and first-tick packets of every joiner by a tick, which `tests/sql/900` pins (tick placement of the pairing bundle, vanilla recordings).  It would take the worst tick to about 50-60 ms; it is the next step.
The dynamics' own cost (`mc.dyn_step`, 7-17 ms in every tick of this run, 100 ms every 4th tick before) and the chunk packet read for a joiner's first 49 chunks (3-5 ms of the join) are the other large items; the 480 `mc.chunk_wanted` rows per joiner became a cursor in round 3.
A first A/B of this round was discarded: a function-extraction slip of mine re-applied `sql/315` over the database (pre-`433` `mc.pid`/`mc.sid`, `proto.frame` and `proto.varint`: `mc.pid` per row 400 us), which made "before" look worse (10 s ticks) and polluted the profiles; the database was rebuilt and its function hashes compared with a fresh migration (identical except the development gateway) before the numbers above.

**Round 2 verification.**  `tests/sql/920` has 43 checks now (the VarInt and waypoint-body equivalences, the entity-phase pass against the previous pass on random states, the slices of the bar's UNTRACKs against the previous pass).  Full suite (`tests/sql/prun.sh`, JOBS=2, shared machine): 74 files, 2,949 checks, all pass except `tests/sql/970_quiet_gate.sql` once ("the gate is armed after quiet ticks": a timing check of the idle track,
not involved with these changes; it passes alone, 92 checks, and the suite run was at load 3-5); `tools/check_overrides.py`, `tools/check_inlining.sh`, `tools/check_fresh_migration.sh` green; gateway unit tests 3 + 58 pass.  `tests/e2e` was not run.

## Round 3: the chunk path without a row per chunk (`sql/1020_chunk_cursor.sql`)

`docs/PERF-STORM-MEASURED.md` put two items of a join tick at the top of the database's own work: `net.hook_chunks` (8.6 ms of the 19 ms `net.play_begin`) and `mc.deliver_ready_chunks` (8.4 ms a tick); the crowd profile (`docs/perf-crowd-live-profile-2026-11-05.txt`) put
`mc.chunk_wanted` rows of walkers that cross chunk borders (1,063 rows a tick, 7 ms of insert, the same rows found again one by one by the delivery) next to them.  Plans (`auto_explain`, nested) of what a join really spent:
**correction to round 2**: "8 -> 1 ms" for `net.hook_chunks` did not hold.  The existence check was one cost; the other two were a join of the head of the square with `mc.chunk` that the planner ran as a sequential scan of the whole table (4 ms at 8,000 chunks, more as the world grows), and the **480 `mc.chunk_wanted` rows**
of the tail (4.3 ms: heap and three indexes, ~10 buffers a row).  Both are gone now.

**What changed (same bytes, same order, same budgets).**
* **`mc.chunk_cursor`: one row per connection instead of one row per wanted chunk.**  Every chunk of a connection's tail exists and the order they are sent in (nearest first, ties by x then z) is the order of the *spiral* of the square, so "what the connection still wants" is
  "the spiral positions of radius r around (cx, cz) after ordinal `next_o`, except those inside the old square".  `mc.chunk_spiral` (92,000 rows, radii 1-40) is the spiral, precomputed.  `net.hook_chunks` makes a cursor for the 480 chunks after the head, and `net.stream_chunks` (async generation, the crossing path)
  makes one for the 23-47 chunks that entered a walker's square, whenever the connection wants nothing else and every chunk of it exists.  A one-row marker in `mc.chunk_wanted` (dimension `cursor`) keeps the quiet tick, the trim and the sweep of departed connections working without knowing about cursors.
* **Cursors become rows the moment anything could differ**: a border crossing or view change first turns the cursor into the rows it stands for (`mc.chunk_cursor_flush`: same distances, same order); the delivery does the same when the client's view is not the one the cursor was made for, or when one of the chunks it is about to send does not exist (any more).
* **The delivery takes the nearest m positions of every cursor exactly as it takes the nearest m rows** (the same per-connection cap, the same shared cap, the same round robin, the same `dbcraft.tick-budget-ms` scaling) and removes what it sent by moving `next_o`: no probe, no delete per chunk.
* `net.hook_chunks` finds the head with one primary-key probe per chunk (a lateral join) instead of a plan that read all of `mc.chunk`.  The spiral has a covering primary key and an index on `(r, d, o)`: the first ordinal of a walker's cursor is the first entry of an index-only scan (2.6 -> 0.2 ms for 20 cursors in a tick).
* `mc.chunk_cursor` is vacuumed by `tools/janitor.sh`; **not** by the gateway's built-in maintenance list (`gateway/src/config.rs`, Rust, not touched here): it holds one short-lived row per connection, so it stays small without; add it there if a long soak shows bloat.

**Proof** (`tests/sql/1020_chunk_cursor.sql`, 20 checks): the previous `net.hook_chunks`, `net.stream_chunks` and `mc.deliver_ready_chunks` are pasted into the test, and random scripts of joins at different places and view distances, walks over chunk borders (one chunk, diagonal), teleports (near and far),
view-distance changes, leaving connections, chunk generation and **chunks that vanish** run twice from the same state, in async and in inline generation, under small budgets (5 chunks a connection and tick, 14 in all; one a tick; the defaults 64/600).  Per tick and connection the bytes sent (chunk batches, forgets, centres), the bytes of the inline head of every join, the whole wanted set
(rows plus what the cursors stand for, with the distances) and the queue of chunk requests are the same.  It is not vacuous (cursors in at least 8 ticks of an async script, in two connections at a time; 20 ticks of an inline one) and five mutants of the new code are caught: the window in the wrong order, a flush that re-wants the last sent position, a delivery that does not probe the existence of its window,
an end test that drops a cursor whose window was exactly full, a first ordinal that is too late.  (A sixth, "`net.stream_chunks` does not flush at the border", is *not* caught and cannot be: the delivery's own check for a changed view then does the same flush with the same result; that check is tried directly.)

**Measured** (own cluster in `/dev/shm`, 4 cores shared with other agents: load 1.5-6.4, so every number is one alternating old/new pair or a median of three; raw lines in `docs/perf-storm-results.jsonl.txt` (`file` = `round3`, `round3-jbp`) and `docs/perf-storm-round3-micro.txt`).

*Micro benchmark* (`tests/bench/chunkcursor`, in-database, explored world, view distance 10, wall time inside the statement, old = rows, new = cursors):

| | before | after |
|---|---|---|
| `net.hook_chunks` for a joiner (head 49 chunks), ms | 5.4-7.8 (7.4 median of three) | **2.2-2.5** |
| the delivery of the tails of 50 joiners (24,000 chunks over 40 ticks), ms per tick | 39-42 | **11-13** |
| 500 walkers, 20 crossings a tick (460 chunks wanted, all delivered in the same tick): `net.stream_chunks` incl. delivery, ms per tick | 18.0-23.4 (median 18.4) | **12.4-20.3 (median 14.0)** |
| 500 walkers, 35 crossings a tick (805 chunks against the budget of 600: a backlog): ms per tick / wanted rows kept at the end of a tick | 72.8-73.7 / 5,810 | **62.4-69.3 / 3,283** (and 69 cursors) |

When a walker's whole entering strip is delivered in the tick that wants it, the cursor does not save much: the work that remains is reading and framing the packets (the floor); the cursor still replaces the 23 inserts, 23 probes and 23 deletes by one row each of insert and delete.  The gain is in the **backlog and join** regimes (the delivery of the 50 tails: 3.5 x cheaper) and in the DB time of a join.
Observed once and not averaged in: after the 5,800-row backlog run the *old* code needed 807 ms a tick to deliver the 50 tails (32 s in all, a plan over the churned `mc.chunk_wanted`); the cursor delivery of the same step took 15 ms a tick.

*Real clients* (`tools/scoreboard/run.py storm2`, Rust gateway, view distance 10, 20 online, joins in 1 s; one old/new pair per size and repetition, `track_functions = 'pl'` for the per-function times):

| | old | new |
|---|---|---|
| **50 joins** (2 pairs): `net.hook_chunks` ms per join | 8.8, 8.6 | **3.6, 4.9** |
| `mc.deliver_ready_chunks` total over the run, ms | 612 (a first run 2,163: an outlier) | **511, 565** |
| worst tick / p99 / ticks over 50 ms | 82 / 82 / 56 and 80 / 80 / 13 | **77 / 68 / 7 and 73 / 63 / 10** |
| **200 joins**, pair 1 (load 1.5): `net.hook_chunks` ms per join / delivery total, ms | 8.2 / 3,138 | **4.7 / 2,711** |
| worst tick / p99 / ticks over 50 / over 100 / all joined with chunks, s | 102 / 80 / 122 / 1 / 19.1 | 179 / 73 / **42** / 2 / **17.8** |
| **200 joins**, pair 2 (load 3.3-4.6): hook per join / delivery total | 10.5 / 4,535 | **6.9 / 3,786** |
| worst tick / p99 / over 50 / over 100 / all joined, s | 153 / 131 / 190 / 30 / 24.9 | 193 / 145 / **139** / **17** / 24.7 |

The chunk path of a 200-join run costs the database 23% less (hook plus delivery: 4.8 -> 3.7 s and 6.6 -> 5.2 s), ticks over 50 ms are 27-66% fewer.  **The worst tick did not improve** (102 -> 179 and 153 -> 193 are single events, one tick in a run, and pair 2 ran at load 3-5: they are inside the spread of this machine; they come from other items, the tracker's pairing and the dynamics, not from chunks).
Per-run noise is the limit of what can be said from one pair; the in-database numbers (CPU or statement time) are the reliable ones.  *Paced in-database storm* (`tests/bench/joinbudget`, 50 joins into 200 online walkers, 1,500 ticks, two pairs): within noise (load 7, `want_chunks` for the walkers' unexplored squares dominates: 600-780 ms a run in both), `hook_chunks` 102 and 83 ms against 138 and 73 ms: not a result.

**What is still a loss.**  *The tracker pairing deferral is not done* (the visibility agents are editing `sql/905-909` and `tests/sql/900`): with it the worst tick of a join storm would fall towards 50-60 ms; chunk work does not touch it.  The chunk packets of the head (49 packets) and the bytes of the delivery stay: reading and framing 600 chunks a tick is 8-11 ms of every storm tick whatever holds the queue.
Walkers that cross a border again before the previous strip is delivered turn their cursor into rows (a backlog of 3,283 rows instead of 5,810 at 35 crossings a tick, not zero), and cursors exist only where every chunk of the strip exists: the first walk through unexplored terrain is rows as before (the `want_chunks` cost of exploring is untouched).
The inline generation mode keeps rows for border crossings (it sends them in the same tick); only the join tail uses a cursor there.

## Raw results

`docs/perf-storm-results.jsonl.txt`: (`file` = `round3` and `round3-jbp`: the round-3 old/new pairs, with `docs/perf-storm-round3-micro.txt`; `file` = `round2-ab2`: the round-2 A/B runs, tags `ab2-vanilla` / `ab2-old` / `ab2-new`) one JSON line per run of the post-restart session (`file` = `fin1`: real clients, 50 joins and one 200 set; `fin2`: the 200-join repetition; `jbp`: the paced in-database runs, including the 200-join runs with the earlier overdue rule), without the per-sample arrays.
The first session's raw file was lost with `/dev/shm` when the container restarted.

## Reproduce

```
tests/e2e/setup.sh                                    # own cluster: DBCRAFT_PGDATA, DBCRAFT_PGPORT (never /tmp for the data)
SCORE_GATEWAY=rust tools/scoreboard/run.py storm2 --n 200 --reps 3 --servers vanilla,dbcraft --tag x      # the real-client storm with chat probes (SCORE_PGDATA, SCORE_PGPORT, SCORE_GW_PORT, SCORE_VANILLA_*, SCORE_OUT, SCORE_HEAP)
PGPORT=... PGDATABASE=... python3 tests/bench/chunkcursor/run.py --reps 3 --xmod 25      # round 3: old (rows) against new (cursors), in-database
JB_PORT=... JB_DB=... python3 tests/bench/joinbudget/run.py --joiners 200 --online 200 --budget 25 --vd 10 --side 30 --walk 0.2     # paced, CPU time per tick
```
