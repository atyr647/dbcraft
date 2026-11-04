# Scoreboard: dbcraft against the real vanilla 26.3 server

The same scenarios, run one after the other on the same 4-CPU machine, against the **real vanilla 26.3 server** (jar pinned by SHA-1, Java 25, `-Xms2G -Xmx2G`, G1)
and against **dbcraft** (PostgreSQL 16, the PL/Python development gateway, native deflate not used).  Vanilla and dbcraft alternate across repetitions
(V D V D) so drift in the machine's load hits both.  Both run offline, flat world, no compression, view distance 10, simulation distance 10.
Everything that produced the numbers is in `tools/scoreboard/`; the full generated table is `docs/SCOREBOARD-table.md`, the raw results
`docs/scoreboard-results.jsonl.txt`.

**Short answer: dbcraft does not beat vanilla across the board.**  It wins most of the scenarios here, but several of those wins come from doing less work,
and it loses (or fails) on login-storm stalls and long runs with 200 moving players (large fills were a loss until the box fill, item 5 below).  (Idle cost and chat latency at low load were losses in the original session and are closed since [PERF-IDLE.md](PERF-IDLE.md): re-measured rows are marked with a dagger below.)  Details below.

## How to read the numbers

* **Tick time.**  Vanilla: its own `/tick query` (mean of the 100-tick windows over the measurement; "p99" = median of the windows' p99).  dbcraft: `ms_total` of
  `mc.server_tick_log` per tick (true per-tick percentiles).  The windows are 45 s of steady state after all clients have their chunks, **world pre-generated**
  on both servers (the measurement is the tick, not world generation).  dbcraft's number does NOT include the PL/Python gateway loop; its CPU does (see CPU).
* **CPU** = all threads of the server (vanilla: the JVM; dbcraft: the Postgres process tree including the gateway backend), cores used over the window.  The
  load generator is excluded.  **Memory** = PSS (shared memory counted once).  Vanilla's 2 GB heap is my `-Xms2G`, not what it needs.
* **Chat round trip** = a probe client sends a chat message and waits for the broadcast to come back: what a player feels, comparable across both servers.
* Players are spread over 960 x 960 blocks (about 22 viewers each) and walk at 4.3 blocks/s in random headings; idle players send `client_tick_end` each tick
  like a real client.  The clients ask for view distance 10 with `client_information` (vanilla otherwise serves only 2).
* The machine was NOT quiet: other jobs ran during part of the session (load average 1 to 7).  Each run records the load; the table notes how many runs happened
  on a busy machine, and the spread is shown.  Differences inside the [min-max] ranges, or under 10%, are called ties.  Most cells have 2 repetitions: the
  spread is a hint, not a confidence interval.
* dbcraft ran in **batched tick** mode: chosen by measurement (200 players, 20% moving: batched 30.6 ms against 36.6 ms for the default tick, p99 73-91 ms against
  about 170 ms).  See "Bugs found" for what that choice cost.

## Headline table (medians; ratio = dbcraft / vanilla, lower is better)

| Scenario | Metric | vanilla | dbcraft | ratio | winner |
|---|---|---|---|---|---|
| idle, 0 players † | tick mean (ms) | 0.35 | 0.11 | 0.31 | dbcraft |
| idle, 0 players † | CPU (cores) | 0.018 | 0.022 | 1.2 | **vanilla** (by 0.004 cores) |
| idle, 0 players | memory (MiB) | 1394 | 175 | 0.13 | dbcraft (vanilla's `-Xms2G`) |
| 50 players, idle † | tick mean / p99 (ms) | 37.3 / 74 | 3.2 / 5.9 | 0.09 / 0.08 | dbcraft |
| 50 players, idle † | CPU (cores) | 0.92 | 0.125 | 0.14 | dbcraft |
| 50 players, idle † | chat round trip p50 (ms) | 11.2 | 4 | 0.36 | dbcraft |
| 50 players, all walking | tick mean / p99 (ms) | 63.8 / 179 | 21.5 / 44.4 | 0.34 / 0.25 | dbcraft |
| 50 players, all walking | chat round trip p50 / p99 (ms) | 64.9 / 225 | 64.9 / 113 | 1.0 / 0.5 | tie / dbcraft |
| 200 players, idle † | tick mean / p99 (ms) | 56.5 / 103 | 6.8 / 11.2 | 0.12 / 0.11 | dbcraft |
| 200 players, idle † | chat round trip p50 / p99 (ms) | 34.7 / 97 | 9 / 28 | 0.26 / 0.29 | dbcraft |
| 200 players, 20% walking | tick mean / p99 (ms) | 58.9 / 113 | 21.8 / 45.6 | 0.37 / 0.40 | dbcraft |
| 200 players, 20% walking | CPU (cores) | 1.48 | 0.66 | 0.44 | dbcraft |
| 200 players, all walking | tick mean / p99 (ms) | 46.7 / 149 | 29.1 / 104 | 0.62 / 0.70 | dbcraft |
| 200 players, all walking | chat round trip p50 / p99 (ms) | **9,424** / 10,881 | 103 / 696 | 0.01 / 0.06 | dbcraft |
| login storm, 50 joins in 1 s ‡ | all joined and all chunks received (s) | 60.8 | 16.9 | 0.28 | dbcraft (machine at load 7-18; 47 against 6.5 s on the quieter day of the first re-measurement) |
| login storm, 50 joins in 1 s ‡ | worst tick during the storm (ms; vanilla: worst 100-tick window p99, dbcraft: worst tick) | 1,409 | 265 | 0.19 | dbcraft (both noisy: ranges 244-2,269 and 148-368) |
| login storm, 50 joins in 1 s ‡ | chat round trip of players already online, p99 / max (ms) | 5,064 / 5,085 | 417 / 437 | 0.08 | dbcraft (median round trip 548 against 208 ms; 27 against 108 ms on the quieter day: vanilla wins the median there) |
| login storm, 200 joins in 1 s (original session, **not re-measured**: the final code could not be run with real clients on a usable machine, see [PERF-STORM.md](PERF-STORM.md)) | all joined and all chunks received (s) | 63.7 | 17.9 | 0.28 | dbcraft |
| login storm, 200 joins in 1 s (original session, same note; its "worst tick" compared vanilla's worst 100-tick window average with dbcraft's single worst tick, see ‡) | worst tick during the storm (ms) | 53.5 | 5,726 | 107 | not comparable: re-measured vanilla window p99 407 and 1,281 ms, window average 85-130 ms, chat stalls of 2.4-4.3 s for the players online |
| one joiner, unexplored world | all chunks (s) | 5.2 | 0.68 | 0.13 | dbcraft |
| one joiner, explored world | all chunks (s) | 1.78 | 0.25 | 0.14 | dbcraft |
| single block edit (admin path) | latency p50 (ms) / edits per s | 1.01 / 749 | 0.11 / 6,852 | 0.11 | dbcraft (RCON against SQL) |
| fill 1,000 blocks | p50 (ms) | 9.98 | 1.43 (was 11.77) | 0.14 | dbcraft (re-measured, item 5 below) |
| fill 100,000 blocks | p50 (ms) | 201 | 42.8 (was 535) | 0.21 | dbcraft (re-measured, item 5 below) |
| 10,000-chunk flat world | generate (s) | 17.8 | 1.15 | 0.06 | dbcraft |
| 10,000-chunk flat world | size after save (MiB) ‡ | 62.1 | **16.1** (was 82.5 in the original run, 92.6 on the tree before this change) | 0.26 | **dbcraft** (re-measured, item 6 below and [PERF-DISK.md](PERF-DISK.md)) |
| 10,000-chunk flat world | save stall: `save-all flush` / `checkpoint` (s) | 13.65 | 0.07 | 0.005 | dbcraft |
| 10,000-chunk flat world | `kill -9` to accepting logins (s) | 10.7 | 2.1 | 0.19 | dbcraft |
| `kill -9` after an edit 1 s old, never saved | edit survives? | no | yes | | dbcraft (dev cluster has `fsync=off`: a power cut is NOT covered) |
| entities, re-measured for [PERF-MOBS2.md](PERF-MOBS2.md) ‡ | 5,000 resting items, viewer in range (ms per tick, CPU) | 96.9 | 1.4 | 0.014 | dbcraft |
| entities, re-measured ‡ | 2,000 walking mobs, viewer in range (ms) | 65.6 | 10.9 | 0.17 | dbcraft |
| entities, re-measured ‡ | 5,000 walking mobs, viewer in range (ms) | 178.6 | 18.2 | 0.10 | dbcraft |
| entities, re-measured ‡ | 2,000 / 5,000 mobs nobody can see (ms) | 5.2 / 10.1 | 12.0 / 19.2 | 2.3 / 1.9 | **vanilla** |
| 200 players walking inside the explored area, 10 minutes | whole run | completes (tick 55.7 ms mean, p99 199, GC 364 pauses max 43 ms, tick 50.7 -> 60.9 ms from first to last third) | **all 200 clients timed out about 4 minutes in** | | **vanilla** |

‡ **Re-measured** for [PERF-STORM.md](PERF-STORM.md) with the Rust gateway, with 20 players online (12 idle bots, 8 chat probes) before the storm, view distance 10, vanilla and dbcraft interleaved, 3 repetitions, medians; a machine at load average 7-18 throughout (other agents), vanilla heap 2 GB.
The old "worst tick" of vanilla (44.7 and 53.5 ms) was the worst 100-tick window average, which hides stalls; the table now uses the window p99 and the chat round trip of the players online, the same on both servers.  dbcraft's number is after the storm work (chunk square spread over ticks, join entry budget, time-scaled chunk cap); the same runs with the previous code measured 854 ms worst tick and a chat p99 of 2,005 ms.

† **Re-measured** for [PERF-IDLE.md](PERF-IDLE.md) on a different day and a quieter machine than the original session, both servers, 2 repetitions of 60 s for vanilla (3 for the empty server) and 3 for dbcraft (PL/Python gateway and batched tick, as in this table; the Rust gateway is in PERF-IDLE.md), after the idle-cost work: medians, ranges and the
before-the-work numbers on the same machine are there.  The other rows are the original session's, and `SCOREBOARD-table.md` / `scoreboard-results.jsonl.txt` still show it.  The original session's values for the changed rows were: idle tick 0.27 / 1.92 ms, CPU 0.01 / 0.11; 50 idle tick 40.0 / 7.4 ms, CPU 0.84 / 0.20, chat p50 24.7 / 43.1 ms;
200 idle tick 71.7 / 22.7 ms, chat 46 / 74 ms p50 and 113 / 406 ms p99 (vanilla / dbcraft).  Chat percentiles rest on about 60 round trips per run.

‡ **Re-measured** for [PERF-DISK.md](PERF-DISK.md): the dbcraft figure is `sum(pg_total_relation_size)` of the five world tables after generating the 10,000 chunks with `mc.generate_batch` and a checkpoint (the query of `run2.scenario_world10k`), 16.14 MiB; the vanilla figure is the same scenario's RCON recipe re-run (62.09 MiB, `du -sb` of the world folder after `save-all flush`).  The other rows are the original session's.
‡ **Edit rows re-run on the current tree** ([PERF-WORLD2.md](PERF-WORLD2.md) section 4, `tests/bench/world2/scoreboard_edit.py`, V D V D, 2 repetitions, both servers on the same busy machine: **load average 13 to 17**, so
every time is 5 to 15 times what it was in the original quiet-ish session and the rows above keep their original values).  Nobody in range, vanilla / dbcraft, median of the p50s: single block edit 4.34 / **0.16** ms,
fill 1,000 blocks 20.3 / **8.6** ms, fill 100,000 blocks **3,080** / **188** ms (ratios 0.04, 0.42, 0.06; originally 0.11, 0.14, 0.21).  With a player in range: single edit 34.1 / 0.15 ms (tick 0.11), fill 1,000 blocks 35.7 / 6.6 (tick 4.1),
fill 100,000 blocks 1,571 / 182 (tick 14.5).  Better evidence for the large fills, in CPU time: with a player in range vanilla's main thread spends 239 to 286 ms (command plus broadcast) and all its threads 647 to 765 ms on the 100,000-block
fill, while dbcraft's tick now spends 3 to 9 ms (it was 240 to 320) and the whole fill about 110 ms at load 8 to 10 (PERF-WORLD2.md section 1).  Vanilla's 201 ms above is a wall-clock RCON round trip without a player; it did not reproduce under load.

## Where dbcraft loses, ranked by how much it matters in real play

1. **It cannot hold 200 moving players for more than about 4 minutes.**  In every dbcraft run of 5 minutes or more with 200 walking players (default tick and
   batched tick, bounded and unbounded walks) all clients were sent `disconnect.timeout` within a few seconds of each other.  200 idle players for 6 minutes: no
   failure.  20 walking players for 8 minutes: no failure.  Timeline of one run (sampled every 20 s): keep-alive rounds were answered normally for ~3,700 ticks
   (pending 0-19 players), then one round was answered by nobody (201 pending) and 600 ticks later everyone was kicked.  The SQL tick stayed at about 25-30 ms
   while the **gateway loop time (`net.gateway_control.last_tick_ms`) climbed from 3 ms to about 85 ms and its late ticks from 0 to over 3,000**.
   **Leading hypothesis (not proven): the PL/Python development gateway degrades with time under 200 walking connections** (Python-side buffers per
   connection); the real gateway should remove it.  It is a gateway problem until shown otherwise, but it is what a player would see.
   Reproduce: `tools/scoreboard/run.py pop --n 200 --moving 1.0 --bound 500 --hold 360 --servers dbcraft --dbmode default --tag x`, with
   `tools/scoreboard/diag_poll.sh 600` alongside; the decoded reasons are in the result (`disconnect_reasons`).
2. **Login storms stall the tick** (0.44 s for 50 joins in 1 s, 5.7 s for 200, original session): the joins were processed inside the one tick.  **Reduced, not closed** ([PERF-STORM.md](PERF-STORM.md)): the cause was mostly each joiner's 529-chunk square sent inside its own join tick at view distance 10 (80 ms of the 100 ms per join), now spread over ticks;
   logins enter play at most one or two per tick; the worst tick of a 50-join storm is 265 ms (3 times less, load 7-18), CPU time of the worst tick 140 ms at 50 joins and 230-250 ms at 200 joins into 200 players (before: 4-8 s).  **Not at 55-60 ms.**  Vanilla's real worst tick in a storm is not 45-55 ms either (its window p99 was 200-246 ms at 50 joins and 407-1,281 ms at 200, online players saw chat stalls of up to 0.85 and 4.3 s);
   the old comparison put its 100-tick average against dbcraft's single worst tick.  The median chat round trip of players online is still higher on dbcraft in a quiet storm (108 ms against 27 ms).
3. ~~**Idle cost: 7 times the tick time and 11 times the CPU** of an idle vanilla (1.9 ms and 0.11 cores).~~  **Closed** ([PERF-IDLE.md](PERF-IDLE.md)): an empty server's tick is 0.11 ms (a quiet tick: one predicate, the clock, a log row) and it uses 0.022-0.030 cores, of which half was the two chunk generators polling every 5 ms; vanilla's 0.018 cores is
   still slightly lower.  With idle players the SQL tick is 2-3 times shorter (phases with nothing to do are skipped, `client_tick_end` is no longer queued).  Not done: the PL/Python gateway still costs 6.8 ms per tick at 200 idle players (it does not filter `client_tick_end`).
4. ~~**Chat latency at low load and in the tail**: +18 ms at p50 with 50 idle players, p99 406 ms against 113 ms with 200 idle players.~~  **Closed for idle players and scripted clients** ([PERF-IDLE.md](PERF-IDLE.md)): an urgent lane handles a chat packet between ticks (same function, same bytes, 20 Hz untouched):
   p50 4-6 ms at 50 and 9-10 ms at 200 idle players, p99 16 and 28-41 ms.  Not measured: chat from real clients, whose other packets in the same 50 ms window make the lane step aside (the message then waits for the tick, as before); the tail during a long tick (login storm, keep-alive round) is still the length of that tick.
5. **Large fills (fixed afterwards, see below)**: 100,000 blocks took 535 ms against 201 ms (5.3 against 2.0 microseconds per block) because every block was rewritten and queued as
   its own event row.  After the box fill (`mc.fill_section`, docs/WORLD.md "Large fills") the same statements take **42.8 ms** (median of five repetitions; each repetition's p50 was
   41.3 to 56.0 ms, single calls 39.5 to 79.7 ms) and 1,000 blocks take 1.43 ms (was 11.77).  Measured with `tools/scoreboard/fill_dbcraft.py` on the shared dev cluster against
   a migrated database: the same SQL statements and the same `\timing` method as `run2.scenario_blocks`, **not the full harness**.  **Vanilla was not re-run** (201 ms and 9.98 ms are
   the earlier run's), and the machine was busier now than then: the OLD code, run the same way in the same hour, measured 7.2 ms and 691 ms, not 11.77 and 535.  So the ratio to vanilla
   (0.21 for 100,000 blocks) mixes two sessions: read it as "clearly faster than vanilla's RCON `fill`", not as a precise factor.  The fill also does less than vanilla's: no light
   update, no neighbour updates, heightmaps recomputed later (docs/WORLD.md says what that moves to the next chunk send).  **With a player in range** the tick that followed the fill
   spent another 243 to 309 ms encoding the 48 section packets (docs/WORLD.md "Large fills"); **since [PERF-WORLD2.md](PERF-WORLD2.md) it spends 3 to 9 ms** (vanilla's main thread: 240 to 290 ms for command and broadcast); this scenario has no player, on either server.
6. ~~**Disk**: a 10,000-chunk flat world is 33% bigger (82.5 against 62.1 MiB): the wire-format sections plus caches against compressed region files.~~  **Closed for flat worlds, partly for terrain** ([PERF-DISK.md](PERF-DISK.md)).  Re-measured: the tree before the change was 92.6 MiB (1.49x); rows are now compressed inside their pages (`sql/950`, the compact storage profile): **16.1 MiB, 0.26x of vanilla's 62.1 MiB** (vanilla re-run today: 65,108,563 bytes, 15,876 chunk entries of 4 KiB because it also writes the 5,060 unfinished border chunks; dbcraft needs 1,692 bytes a chunk, vanilla stores 4,096).  Measured with the scoreboard's own size query (`tools/scoreboard/run2.py`, `world_bytes`) on a cluster of its own, **not the full harness**; vanilla's number is the same recipe re-run, not the original run's.  Real terrain, same measure: the imported vanilla world (780 chunks) is 13.35 MiB after `tools/compact_world.sh` (17.84 as the importer writes it) against **17.08 MiB for vanilla's whole folder but 7.23 MiB for the 780 full chunks alone: dbcraft is 0.78x the first and 1.8x the second**; 2,000 chunks of `dbcraft:noise` are 13.34 MiB after compaction against 7.84 MiB for their export (1.7x).  **Not closed**: a terrain chunk that has been sent keeps a 14.7 KB packet cache row (24.35 MiB for the imported world with every chunk sent), `mc.trim_chunk_cache()` drops it at the price of a rebuild on the next send; and vanilla's per-chunk deflate beats per-row lz4/pglz by 1.8x on terrain.  Hot-path cost: `set_block` 0 to +3% CPU, `get_block` +3 us, `set_blocks`/`fill`/rebuild/join unchanged or faster (PERF-DISK.md section 5).
7. **Mobs**: about 150 microseconds per awake mob against vanilla's 22 (`docs/ENTITY.md`; the worker that later optimised it reports a lower figure in its own doc).
7. ~~**Mobs**: about 150 microseconds per awake mob against vanilla's 22.~~  **Closed where a player can see the mobs, still a loss where nobody can** ([PERF-MOBS2.md](PERF-MOBS2.md)): re-measured against the real server,
   2,000 and 5,000 awake walking cows cost the entity tick 10.9 and 18.2 ms of CPU (5.5 and 3.6 us per mob) against 65.6 and 178.6 ms for the vanilla server thread; 5,000 resting items 1.4 against 96.9 ms.
   Cows that no viewer's cell contains cost dbcraft 12.0 / 19.2 ms (2,000 / 5,000) against vanilla's 5.2 / 10.1: vanilla's idle cow in an unobserved region costs 2-2.6 us per tick, dbcraft's mob
   3.8-6 us (an event is a row update through SQL), and dbcraft despawns such mobs after 600 ticks anyway.  ‡ Method and caveats: both sides CPU time, the machine loaded (vanilla's wall-clock tick times
   unusable), 3 repetitions, vanilla and dbcraft not interleaved in the final numbers, `-Xmx1G` for vanilla; dbcraft models no pathfinding, goals, look-around, motion packets, sounds or collision.

## Where dbcraft wins

* **Tick time and CPU with 50-200 players** (2.7-5.5 times less tick, 1.5-4 times less CPU), **but see the caveat below: dbcraft does less work.**
* **Chunk generation (15 times faster) and first joins (7.6 times faster)**: set-based generation against a per-chunk pipeline.
* **No save stall**: vanilla's `save-all flush` blocks 13.7 s with 10,000 loaded chunks; dbcraft's checkpoint runs in the background.
* **Crash recovery 5 times faster and a 1-second-old edit survives** (vanilla loses everything since the last save).  The dev cluster runs with `fsync=off`, so
  this measures a killed process, not a power cut.
* **Single admin edits 9 times faster** (SQL against RCON), resting-item populations 70 times cheaper (re-measured, PERF-MOBS2.md; 12 times in the original session), and awake mobs that a player can see 6 to 10 times cheaper in CPU than the vanilla server thread.
* **Under overload vanilla's chat round trip grows to 9-24 seconds** with 200 walking players; dbcraft's stays near 100-180 ms.  (Vanilla queues packet work behind
  its saturated main thread; I did not investigate further.)

## What is NOT comparable (read before quoting any ratio)

* dbcraft **does less**: no random ticks, no entity tracking beyond players, no mobs, no lighting updates, no redstone or fluids, no per-chunk simulation, flat
  terrain only.  Vanilla's tick at 50 idle players is mostly per-chunk work that dbcraft does not do at all.  The tick ratios are therefore an upper bound on what a
  feature-complete dbcraft would show.
* Flat world only; no terrain generation cost, no structures, no biomes.
* Vanilla's heap is fixed at 2 GB and its JVM was freshly started for every run (JIT warm-up is part of it: over the 10-minute run its tick did not improve).
* CPU/memory definitions differ (JVM threads against a process tree).
* The PL/Python gateway is a development gateway; the real one will change the CPU, latency and long-run results.
* Idle and walking bots are not real players: no inventory, no block interaction, no chat spam.

## Bugs found while measuring

* **Fixed (in this branch, with a regression test):** the batched tick never delivered chunks that were generated after the player joined (asynchronous generation):
  a joiner into an unexplored world received **no chunk at all**.  `sql/389_batch_tick.sql` now calls `mc.deliver_ready_chunks()`; `tests/sql/430_chunk_queue.sql`
  part 3 fails without it (`got 0 want 49`).  The batched streaming variants (`net.stream_chunks_batched`/`_ref`) also still generate chunks for crossing players
  inline, on the tick, which the asynchronous default does not.
* **Open:** the long-run keep-alive timeouts above (hypothesis: the development gateway).
* **Harness, found and fixed:** vanilla clients saw only 49 chunks until the load generator sent `client_information`; vanilla's own watchdog killed the server
  during a 7,225-chunk `forceload` (now small waited rectangles, watchdog off for setup only); forced chunks persisted and made a restarted vanilla load 10,000
  chunks before accepting logins; `gamerule max_block_modifications` (not `command_modification_block_limit`) lifts vanilla's 32,768-block fill limit; the
  `kill -9` helper killed Postgres children first.  Earlier results with those flaws were removed (their rows are relabelled in the raw file).
* dbcraft's `mc.server_tick_log` keeps only the last 6,001 ticks, so the tick statistics of runs longer than 5 minutes cover only their last five minutes.

## What was not run

* Scenario 6b (1,000 edits per tick with 100 watchers): not run.  Scenario 5 (entities with 0 and 100 players): re-run for PERF-MOBS2.md with one viewer and with none in range (not 100 players).
* 500 players: not run (the load generator and the loaded machine were the limit; 200 was the largest size).
* Through the Rust gateway: not run, no built gateway existed at the time.
* Most cells have 2 repetitions, the storms and the 10,000-chunk world 1; no confidence intervals.
* A quiet machine: runs overlapped other jobs' load (recorded per run).

## Reproduce

```
tools/scoreboard/dbcraft.sh setup-db         # own cluster on port 54599 (tests/e2e/setup.sh with overrides)
tools/scoreboard/matrix.py --phase all       # modes, idle, core, storm, misc, tail (hours); rerun.sh / rerun2.sh are the re-runs described above
tools/scoreboard/aggregate.py --tags core,storm,misc2,misc3,tail2,tail-unbounded     # the table
tools/scoreboard/details.py                  # block-edit responses, tail and chunk loading details
```
Needs: the vanilla jar at `/tmp/jar-dl/server.jar` (SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`), Java 25, PostgreSQL 16 with plpython3u, the data generator reports.
