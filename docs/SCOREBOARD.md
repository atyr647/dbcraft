# Scoreboard: dbcraft against the real vanilla 26.3 server

The same scenarios, run one after the other on the same 4-CPU machine, against the **real vanilla 26.3 server** (jar pinned by SHA-1, Java 25, `-Xms2G -Xmx2G`, G1)
and against **dbcraft** (PostgreSQL 16, the PL/Python development gateway, native deflate not used).  Vanilla and dbcraft alternate across repetitions
(V D V D) so drift in the machine's load hits both.  Both run offline, flat world, no compression, view distance 10, simulation distance 10.
Everything that produced the numbers is in `tools/scoreboard/`; the full generated table is `docs/SCOREBOARD-table.md`, the raw results
`docs/scoreboard-results.jsonl.txt`.

**Short answer: dbcraft does not beat vanilla across the board.**  It wins most of the scenarios here, but several of those wins come from doing less work,
and it loses (or fails) on idle cost, login-storm stalls, long runs with 200 moving players and chat latency at low load (large fills were a loss until the box fill, item 5 below).  Details below.

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
| idle, 0 players | tick mean (ms) | 0.27 | 1.92 | 7.0 | **vanilla** |
| idle, 0 players | CPU (cores) | 0.01 | 0.11 | 10.6 | **vanilla** |
| idle, 0 players | memory (MiB) | 1394 | 175 | 0.13 | dbcraft (vanilla's `-Xms2G`) |
| 50 players, idle | tick mean / p99 (ms) | 40.0 / 82 | 7.4 / 19.7 | 0.18 / 0.24 | dbcraft |
| 50 players, idle | CPU (cores) | 0.84 | 0.20 | 0.24 | dbcraft |
| 50 players, idle | chat round trip p50 (ms) | 24.7 | 43.1 | 1.7 | **vanilla** |
| 50 players, all walking | tick mean / p99 (ms) | 63.8 / 179 | 21.5 / 44.4 | 0.34 / 0.25 | dbcraft |
| 50 players, all walking | chat round trip p50 / p99 (ms) | 64.9 / 225 | 64.9 / 113 | 1.0 / 0.5 | tie / dbcraft |
| 200 players, idle | tick mean / p99 (ms) | 71.7 / 157 | 22.7 / 52.1 | 0.32 / 0.33 | dbcraft |
| 200 players, idle | chat round trip p50 / p99 (ms) | 46 / 113 | 74 / 406 | 1.6 / 3.6 | **vanilla** |
| 200 players, 20% walking | tick mean / p99 (ms) | 58.9 / 113 | 21.8 / 45.6 | 0.37 / 0.40 | dbcraft |
| 200 players, 20% walking | CPU (cores) | 1.48 | 0.66 | 0.44 | dbcraft |
| 200 players, all walking | tick mean / p99 (ms) | 46.7 / 149 | 29.1 / 104 | 0.62 / 0.70 | dbcraft |
| 200 players, all walking | chat round trip p50 / p99 (ms) | **9,424** / 10,881 | 103 / 696 | 0.01 / 0.06 | dbcraft |
| login storm, 50 joins in 1 s | all joined and all chunks received (s) | 51.7 | 3.5 | 0.07 | dbcraft |
| login storm, 50 joins in 1 s | worst tick during the storm (ms) | 44.7 | **444** | 9.9 | **vanilla** |
| login storm, 200 joins in 1 s | all joined and all chunks received (s) | 63.7 | 17.9 | 0.28 | dbcraft |
| login storm, 200 joins in 1 s | worst tick during the storm (ms) | 53.5 | **5,726** | 107 | **vanilla** |
| one joiner, unexplored world | all chunks (s) | 5.2 | 0.68 | 0.13 | dbcraft |
| one joiner, explored world | all chunks (s) | 1.78 | 0.25 | 0.14 | dbcraft |
| single block edit (admin path) | latency p50 (ms) / edits per s | 1.01 / 749 | 0.11 / 6,852 | 0.11 | dbcraft (RCON against SQL) |
| fill 1,000 blocks | p50 (ms) | 9.98 | 1.43 (was 11.77) | 0.14 | dbcraft (re-measured, item 5 below) |
| fill 100,000 blocks | p50 (ms) | 201 | 42.8 (was 535) | 0.21 | dbcraft (re-measured, item 5 below) |
| 10,000-chunk flat world | generate (s) | 17.8 | 1.15 | 0.06 | dbcraft |
| 10,000-chunk flat world | size after save (MiB) | 62.1 | **82.5** | 1.33 | **vanilla** |
| 10,000-chunk flat world | save stall: `save-all flush` / `checkpoint` (s) | 13.65 | 0.07 | 0.005 | dbcraft |
| 10,000-chunk flat world | `kill -9` to accepting logins (s) | 10.7 | 2.1 | 0.19 | dbcraft |
| `kill -9` after an edit 1 s old, never saved | edit survives? | no | yes | | dbcraft (dev cluster has `fsync=off`: a power cut is NOT covered) |
| entities (from `docs/ENTITY.md`, not re-run here) | 5,000 resting items (ms) | 53-56 | 4.4 | 0.08 | dbcraft |
| entities (same) | 2,000 walking mobs (ms) | 44-50 | 106 | 2.2 | **vanilla** |
| 200 players walking inside the explored area, 10 minutes | whole run | completes (tick 55.7 ms mean, p99 199, GC 364 pauses max 43 ms, tick 50.7 -> 60.9 ms from first to last third) | **all 200 clients timed out about 4 minutes in** | | **vanilla** |

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
2. **Login storms stall the tick** (0.44 s for 50 joins in 1 s, 5.7 s for 200): the joins are processed inside the one tick.  Vanilla's ticks stay near 50 ms and its
   joiners just wait longer.  Physics of the design (one transaction per tick); mitigations: admit a few joins per tick, make the entry burst cheaper.  Everyone
   already online would see a freeze of that length, which is worse than a slow join.
3. **Idle cost: 7 times the tick time and 11 times the CPU** of an idle vanilla (1.9 ms and 0.11 cores).  A tuning gap: a fixed set of statements and the Python loop
   run every tick even with nothing to do (the batched tick already cut it from 16.6 ms to 2.6 ms with no players in `docs/PERF-BATCH.md`).
4. **Chat latency at low load and in the tail**: +18 ms at p50 with 50 idle players, p99 406 ms against 113 ms with 200 idle players.  The message waits for the
   next tick and then goes through the Python loop.  Partly a tuning gap, partly the 20 Hz quantisation.
5. **Large fills (fixed afterwards, see below)**: 100,000 blocks took 535 ms against 201 ms (5.3 against 2.0 microseconds per block) because every block was rewritten and queued as
   its own event row.  After the box fill (`mc.fill_section`, docs/WORLD.md "Large fills") the same statements take **42.8 ms** (median of five repetitions; each repetition's p50 was
   41.3 to 56.0 ms, single calls 39.5 to 79.7 ms) and 1,000 blocks take 1.43 ms (was 11.77).  Measured with `tools/scoreboard/fill_dbcraft.py` on the shared dev cluster against
   a migrated database: the same SQL statements and the same `\timing` method as `run2.scenario_blocks`, **not the full harness**.  **Vanilla was not re-run** (201 ms and 9.98 ms are
   the earlier run's), and the machine was busier now than then: the OLD code, run the same way in the same hour, measured 7.2 ms and 691 ms, not 11.77 and 535.  So the ratio to vanilla
   (0.21 for 100,000 blocks) mixes two sessions: read it as "clearly faster than vanilla's RCON `fill`", not as a precise factor.  The fill also does less than vanilla's: no light
   update, no neighbour updates, heightmaps recomputed later (docs/WORLD.md says what that moves to the next chunk send).
6. **Disk**: a 10,000-chunk flat world is 33% bigger (82.5 against 62.1 MiB): the wire-format sections plus caches against compressed region files.
7. **Mobs**: about 150 microseconds per awake mob against vanilla's 22 (`docs/ENTITY.md`; the worker that later optimised it reports a lower figure in its own doc).

## Where dbcraft wins

* **Tick time and CPU with 50-200 players** (2.7-5.5 times less tick, 1.5-4 times less CPU), **but see the caveat below: dbcraft does less work.**
* **Chunk generation (15 times faster) and first joins (7.6 times faster)**: set-based generation against a per-chunk pipeline.
* **No save stall**: vanilla's `save-all flush` blocks 13.7 s with 10,000 loaded chunks; dbcraft's checkpoint runs in the background.
* **Crash recovery 5 times faster and a 1-second-old edit survives** (vanilla loses everything since the last save).  The dev cluster runs with `fsync=off`, so
  this measures a killed process, not a power cut.
* **Single admin edits 9 times faster** (SQL against RCON), resting-item populations 12 times cheaper.
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

* Scenario 6b (1,000 edits per tick with 100 watchers): not run.  Scenario 5 (entities with 0 and 100 players): taken from `docs/ENTITY.md`, not repeated.
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
