# The login storm, measured again: before and after storm round 2, and vanilla (STORM-MEASURED)

**Short answer.**  On a flat, pre-generated world with a warm chunk-packet cache, view distance 10, the Rust gateway, 20 players online (12 idle bots, 8 chat probes) and N clients connecting within one second,
storm round 2 (`7251b8c`: inlinable waypoint/VarInt paths, sliced UNTRACKs, chunk hook probes, gateway chat lane before a late tick; "before" = its first parent `f62f0f9`, "after" = HEAD, which also has the dynamics, capacity, mobs and idle work) did this:

* **200 joins: the worst tick fell from 485-538 ms to 105-146 ms** (three after runs, two before runs; the ranges do not touch), ticks over 100 ms from 15-16 to 1-2, p99 tick from 112-127 to 80-89 ms,
  the online players' chat during the storm from p50 105 / p99 396-527 / max 574-700 ms to **p50 35-41 / p99 85-120 / max 97-136 ms**, everybody joined with all chunks in 18-20 s instead of 25 s, and the tick backend used about a quarter less CPU for the same storm (15-16 s against 21 s).
* **50 joins: the worst tick is not separable from noise** (before 147 / 72 / 85 ms, after 108 / 75 / 70 ms) and nothing exceeds 150 ms in either tree; what is clear is the chat of the online players (p50 **26** [20-30] against **84** [65-89] ms, p99 57 [56-93] against 154 [140-182]) and the number of ticks over 50 ms (11 [8-14] against 30 [20-40] of about 84).
* **Against vanilla** (one run per size, see the caveats): at 50 joins vanilla keeps the lead in chat p50 (14 ms measured, 28 in the quiet-machine campaign, against 20-30 ms) and is the slowest to finish by a factor of ten (46 s against 4.5 s); at 200 joins dbcraft's worst tick (105-146 ms) and p99 (80-89 ms) are below vanilla's campaign figures (545 ms worst, 120 ms p99), and all joined in 18-20 s against 52-67 s.
* **The cliff at the 121st player is gone** (it was the whole worst tick before: 532 of 596 ms, one tick; on HEAD the same moment adds about 7 ms to each of five ticks).
* **What remains** is a tick of 40-43 ms on average (p50 44-47 ms at 200 joins, 81-130 of about 320 ticks over 50 ms): one join per tick costs about 30 ms of database time (the join itself 19 ms, 8.6 ms of that the chunk head read, plus the tracker's first sync and the rest of the login) on top of a per-tick base of about 22 ms, 8.4 ms of that the chunk delivery step.  See "What remains".

## Results

Machine: 4 cores shared with three other agents, `/dev/shm` clusters (`tools/scoreboard/cenv_capacity`, ports 56600 after and 56610 before, `fsync=off`), `tools/scoreboard/run.py storm2 --n N --vd 10 --online 12 --probes 8` (defaults: spawn spread 480 blocks, 8 s settle, 20 s after), Rust gateway (each tree's own `gateway/build.sh`),
`SCORE_COLD_CACHE` unset (the harness encodes the chunk packets of the pre-generated world before the storm in both trees), the HEAD harness for both trees.  Cells alternated before / after.  Raw rows: `docs/perf-storm-measured-results.txt`; one line per row: `python3 tools/scoreboard/storm_measured_report.py`, `storm_measured_detail.py`.
Ranges are min-max; where there are three runs the first number is the median.  "Load" is the 1-minute load average at the start of the cell.

| | vanilla (1 run, load 2.0 / 2.7) | dbcraft before (`f62f0f9`) | dbcraft after (HEAD) |
|---|---|---|---|
| **200 joins** runs (load at start) | 1 (2.7) | 2: r0 (0.6), r1 (1.1); a profile run (3.3) | 3: r0 (1.2), r1 (1.7), q0 (3.3); a profile run (3.0) |
| worst tick, ms | worst 100-tick window p99 **955** (campaign: worst tick 545) | **485, 538** (profile run 596) | **143, 105, 146** (profile run 118) |
| tick p99, ms | median of the window p99s 247 (campaign 120) | 112, 127 | **86, 89, 80** |
| ticks over 100 ms / over 50 ms | not measurable | 15, 16 / 189, 191 | **2, 2, 1 / 130, 81, 98** (of 314-322 ticks) |
| online chat during the storm, p50 / p99 / max, ms | 342 / 3,504 / 3,713 (campaign: p50 182, p99 2,408) | 105 / 396 / 574 and 104 / 527 / 700 | **41 / 120 / 136, 36 / 85 / 105, 35 / 90 / 97** |
| all joined with all chunks, s | 67.4 (campaign 51.8) | 24.9, 25.6 | **20.3, 18.3, 18.6** |
| tick backend CPU over the storm window, s | | 20.8, 21.7 (60 ms per logged tick) | **16.4, 15.0, 14.6** (46-51 ms per logged tick) |
| clients dropped (storm / online) | 0 / 0 | 0 / 0 | 0 / 0 |
| **50 joins** runs (load at start) | 1 (2.0) | 3: 1.0, 1.1, 3.4 | 3: 0.8, 0.9, 3.4 |
| worst tick, ms | worst window p99 **211** | 147, 72, 85 | 108, 75, 70 |
| tick p99, ms | median window p99 52 | 90, 72, 73 | 102, 74, 66 |
| ticks over 100 ms / over 50 ms (of 83-84) | | 1, 0, 0 / 30, 20, 40 | 2, 0, 0 / 14, 11, 8 |
| online chat during the storm, p50 / p99 / max, ms | **14** / 338 / 485 (campaign: p50 28) | 84 / 182 / 208, 65 / 140 / 147, 89 / 154 / 166 | **30 / 93 / 99, 26 / 56 / 57, 20 / 57 / 58** |
| all joined with all chunks, s | 46.2 (campaign 44.4) | 4.9, 4.3, 4.9 | 4.6, 4.3, 4.3 |
| tick backend CPU over the window, s | | 3.8, 3.4, 3.7 | 3.5, 3.3, 3.2 |
| clients dropped | 0 / 0 | 0 / 0 | 0 / 0 |

Reading notes.  dbcraft's "worst tick" and "p99" are the real maxima and 99th percentile of `mc.server_tick_log` over the storm window (about 84 ticks at 50 joins, 320-360 at 200: the p99 at 50 joins is the second-worst tick, so it is as noisy as the worst).
Vanilla's figures are `/tick query` windows polled twice a second: the **worst 100-tick window's p99**, not a single tick, so they are not directly comparable to dbcraft's maxima (a 100-tick window p99 is a lower bound of the worst tick); vanilla's GC pauses were 18 (max 68 ms) and 25 (max 369 ms) in the two runs.
Chat in the first 8 s before each storm is p50 4-6 ms, p99 17-38 ms in both trees (and vanilla 7-9 ms / 47-65 ms), so the probes themselves are not the limit.

### Paced in-database storm (`tests/bench/joinbudget`, CPU time of the tick backend per tick, view distance 10, 20% of the online walking, budget 25)

On-CPU time (`/proc/self/schedstat`), so load matters little (the load was 3-4 during these, other agents' tests).  The first 8 ticks (the harness's own setup, 380-800 ms each time) are excluded.  Raw: `docs/perf-storm-measured-paced.txt`, `python3 tools/scoreboard/storm_measured_paced_report.py`.

| | before | after |
|---|---|---|
| **50 joins into 20 online**, 3 runs: worst tick CPU ms | 142, 142, 152 | 137, 115, 127 |
| p99 CPU ms | 127, 130, 134 | 126, 104, 111 |
| mean CPU ms per tick | 43.5, 43.0, 45.2 | **30.8, 35.1, 31.3** |
| ticks over 100 ms CPU | 3, 3, 6 | 2, 2, 2 |
| **200 joins into 200 online**, 2 runs: worst tick CPU ms | 332, 416 | **230, 286** |
| p99 CPU ms | 240, 286 | **179, 165** |
| mean CPU ms per tick | 64.3, 74.2 | **55.4, 51.8** |
| ticks over 100 ms CPU | 54, 84 | **32, 34** |
| simulated time until all joined, s | 25.2, 29.8 | 23.3, 22.0 |

In this harness the 200 online players are already past the locator bar's 120-player threshold, so the cliff is not in it; the 50-into-20 worst ticks (ticks 41 and 61: the gate releases a group of joins, process 49-58 ms and game 55-62 ms in a diagnostic run) are the harness's own bursts, the same in both trees.
Mean CPU per tick is 14-31% lower after (50 into 20: 29, 18, 31%; 200 into 200: 14, 30%), the worst tick of the 200 cell 31 and 31% lower.

## Per-phase breakdown of the 200-join storm after the fix

From the profile runs (`SCORE_STORM_PROF=1`: `track_functions = 'pl'`, `pg_stat_reset()` at the start of the window, which costs some CPU, so these runs are not in the table above; their tick figures are in line with the other runs: worst 118 ms after and 596 ms before).
`mc.server_tick_log` phases and `mc.tick_log` game phases (`ms_keepalive` is `dyn_step` + `vis_step` + `survival_entities` + `keepalive_due`, i.e. the world dynamics and the tracker's entity phase; `ms_visibility` is `refresh_visibility`).

Mean tick, ms (317 ticks after, 354 before): process **18.2** (23.1), game **12.6** (19.0), chunks **10.3** (9.4), drain 1.8 (1.9), blocks 0.0.

The five worst ticks after (ms; players in play; frames in / out):

| tick | players | total | process | game | chunks | drain | visibility | dyn + entity vis | frames in / out |
|---|---|---|---|---|---|---|---|---|---|
| 4441 | 213 | **117.8** | 66.7 | 28.1 | 19.4 | 3.6 | 13.5 | 10.6 | 236 / 1,080 |
| 4402 | 174 | 87.1 | 39.8 | 35.8 | 10.0 | 1.6 | 13.5 | 12.5 | 172 / 910 |
| 4269 | 41 | 81.7 | 40.3 | 31.7 | 8.1 | 1.5 | 5.7 | 19.7 | 42 / 410 |
| 4324 | 96 | 80.3 | 37.6 | 27.2 | 13.1 | 2.3 | 3.9 | 20.6 | 123 / 664 |
| 4248 | 21 | 78.9 | 41.6 | 29.9 | 6.8 | 0.5 | 2.8 | 26.3 | 31 / 129 |

The q0 run's worst tick (145.7 ms, 197 players): process 41.9, game 56.9 (visibility 17.8, dyn + entity vis 24.3), chunks 39.5.  Before, the worst tick was **595.5 ms at 121 players: game 545.8 of it, `refresh_visibility` 531.9** (the locator bar switching off: 14,280 UNTRACK packets in one tick);
the next-worst before ticks were 173, 163, 159, 151 ms (the first join ticks: process 75-96 ms).

**The 121st-player cliff on HEAD** (tick log of the after profile run): players 117-120: visibility 3.7-4.5 ms; players 121-125: 10.2-12.6 ms (about +7 ms for five ticks: the slices of 1,500 UNTRACKs), then 4-5 ms again; the tick totals stay 55-61 ms.  It is no longer a tail event.

Functions, `pg_stat_user_functions` over the storm window (ms of total time, nested; calls in brackets where they differ); function time of `mc.server_tick` is 14,059 ms after (357 ticks) and 19,169 ms before (377 ticks):

| function | before | after | note |
|---|---|---|---|
| `net.process_fast` | 8,139 | 5,799 | the input phase: logins, config, play packets |
| `net.h_config` (joins' configuration step, 600 / 604 calls) | 4,391 | 4,039 | contains `net.play_begin` |
| `net.play_begin` (200 joins) | 4,155 (20.8 ms per join) | 3,805 (**19.0 ms per join**) | |
| `net.send_chunks` (200) | 2,064 | 2,017 | the join's first 49 chunks |
| `net.hook_chunks` (200) | 1,774 (self 1,760) | 1,721 (self 1,707): **8.6 ms per join, unchanged** | |
| `net.hook_join_info` | 1,386 | 1,132 | |
| `mc.on_join` | 682 | 616 | |
| `mc.tick_core` (the game phase) | 6,804 | 4,188 | |
| `mc.vis_step` | 3,139 | 2,158 | the tracker's entity phase |
| `mc.vis_wp_pass` (locator bar) | 2,214 | 901 | |
| `mc.refresh_visibility` | 1,987 | 970 | the cliff |
| `mc.pairing_bundle` (2,038 / 2,013) | 759 | 273 | |
| `mc.vis_join` / `vis_first_tick` / `vis_wp_join` (200 each) | 592 / 365 / 411 | 401 / 315 / 265 | |
| `proto.frame` (212k / 203k) | 1,019 | 219 | the VarInt fix |
| `net.stream_chunks` | 3,358 | 3,285 | the per-tick delivery |
| `mc.deliver_ready_chunks` (357 ticks) | 3,171 (self 3,040) | 3,125 (self 3,001): **8.4 ms per tick** | |
| `net.drain_outbox` | 1,084 | 1,165 | |
| `mc.dyn_step` | 205 | 200 | 0.56 ms per tick: the dynamics are not a storm cost on a flat world |
| `net.urgent_chat` (the gateway's chat lane) | | 630 (152 calls, 4.1 ms) | outside `mc.server_tick` |

So round 2 took out what it said it took out (the waypoint pass, the frames, the pairing bundle, the 121st-player tick: 5.1 s of function time over the run, 27%), and left the join itself and the chunk path as they were.

## What remains of the tail, and why

* **The join tick.**  After the fix every join still costs 19 ms in `net.play_begin` (8.6 chunk head and 480 `mc.chunk_wanted` rows, 5.7 `hook_join_info`, 3.0 `mc.on_join`, 1.7 static packets) plus about 6 ms in the tracker (`vis_join` 2.0, `vis_first_tick` 1.6, `pairing_bundle` 1.4, `vis_wp_join` 1.3): **about 30 ms of database time per joiner** (`h_config` 20.2, tracker 6.3, rest of the login about 2.3), one joiner per tick (`join-entry-budget-ms` 10, `join-entry-free` 1).
  On top of a per-tick base of about 22 ms (`mc.deliver_ready_chunks` 8.4, `vis_wp_pass` 2.5, `refresh_visibility_vis` 2.7, `vis_entity_phase` 1.5, `process_fast` and `server_tick` self 5) that is a join tick of 50-60 ms, 80 ms and more when a second login, a chunk burst or the tracker's keep-alive round lands in the same tick: this is the p99 (80-89 ms) and the 80-130 ticks over 50 ms.
  The worst ticks after (105-146 ms) are join ticks that also carry other joiners' configuration step, a chunk delivery of 20-40 ms and a tracker pass: process 42-67 ms, game 28-57 ms, chunks 19-40 ms (two runs only: 4441 and the q0 tick).  They are not the 121st player, not the dynamics (0.56 ms per tick), not the waypoint pass.
* **The chunk path is the largest single block and was not changed by round 2**: `hook_chunks` 8.6 ms per join (`docs/PERF-STORM.md` claims 8 to 1 ms for the existence check; the function's self time did not move, so what dominates is something else in it: reading 49 cached packets of about 7 KB and inserting about 480 wanted rows)
  plus `deliver_ready_chunks` at 8.4 ms self per tick for the whole storm, even in ticks that have little to deliver: together 4.7 s of the 14.1 s of function time (33%), and `net.send_chunks` + `net.stream_chunks` in all 5.3 s (38%).
* **Per-tick work of every tick of a storm** is what keeps the p50 at 44-47 ms: a 20 Hz tick that is already 90% full leaves a chat that arrives mid-tick waiting for the rest of it.  The chat p99 of 85-120 ms is about one worst tick plus the lane.
* **After the storm** the online players' chat p99 is 500-820 ms in every run of both trees (p50 6-10 ms): not a tick (the tick log has one tick over 90 ms in that period and the 220-to-20 players leave tick takes 25 ms), so probably the gateway closing 200 connections at once when the load generators exit; not investigated, not caused by this track.
* **Vanilla at 50 joins** keeps a lower chat p50 (14 ms measured, 28 in the campaign) (its tick is 36 ms on average); dbcraft's 20-30 ms is within about one tick.

### One concrete next step

Take the chunk path apart with `auto_explain` (or `EXPLAIN (ANALYZE, BUFFERS)` of the statements inside `net.hook_chunks` and `mc.deliver_ready_chunks`) in a 200-join run and make it cheaper: it is 33% of the storm's in-database function time, 8.6 ms of every join and 8.4 ms of every tick, none of it touched by round 2.
The measured candidates are the 480-row `mc.chunk_wanted` insert per join (a cursor or an array in `mc.player` instead of rows) and the per-connection index scans of `deliver_ready_chunks` at 600 chunks per tick; the pairing deferral named in `docs/PERF-STORM.md` (admit joins every second tick, slice the tracker's first sync) would lower the worst tick to 50-60 ms but needs the pins of `tests/sql/900` changed and is the larger job.

## Noise and what the numbers can carry

* The machine was shared with three other agents during every cell; the first eight cells ran at load 0.6-1.7 (busy fraction 0.11-0.47), the later ones at load 3.0-3.4 (busy 0.58-0.84), vanilla at 2.0-2.7 (busy 0.57 and 0.71).  CPU time of the tick backend (not wall) is reported next to wall for that reason.
* **200 joins, before against after**: worst tick, ticks over 100 ms, chat p99 and max, time to all joined, CPU: the ranges do not touch with 2 against 3 runs each, the effects are factors of 3-5 (worst tick, ticks over 100, chat max) and 1.3 (time, CPU).  Conclusion carried.  The cells at load 3.3 (profile run, q0) agree with the quiet ones (worst 118 and 146 ms after, 596 before).
* **50 joins**: the chat (p50, p99, max) and the ticks over 50 ms separate (3 against 3 runs, ranges do not touch except p99, 93 against 140); **worst tick and tick p99 do not** (ranges 70-108 against 72-147; one slow tick of a 84-tick window decides them).  CPU time 3.2-3.5 against 3.4-3.8 s: after is lower in every pair but the ranges overlap.
* **Vanilla**: one run per size.  The 50-join run (load 2.0) is usable and agrees with the quiet-machine campaign (46 s against 44.4 s; chat p50 14 against 28 ms is one run's spread).  **The 200-join run is not usable as a vanilla number**: the machine got busy during it (busy 0.71; load average 2.7 at the start and 6.6 at the end, of which the vanilla server and the 220 clients are a part), its worst window p99 (955 ms), its chat (p50 342 ms, p99 3.5 s) and its time (67.4 s) are all worse than the campaign's quiet-machine figures (worst tick 545 ms, p99 120 ms, all in 51.8 s, chat p50 182 ms), which should be cited instead.
* The paced runs are on-CPU numbers with load 3-4; the first 8 ticks are excluded; 2-3 runs per cell; the difference of mean CPU per tick (14-31%) is about as large as the spread between runs (up to 15%), so it is a direction, not a figure, the worst-tick difference at 50 joins is not.
* `pg_stat_user_functions` figures come from one run per tree with `track_functions = 'pl'` and are totals of one storm, not averages: differences below 10-15% (hook_chunks, deliver_ready_chunks, drain_outbox) are noise-level.
* Not repeated: nothing beyond the numbers above; no cold-cache cells (`SCORE_COLD_CACHE=1`), no vanilla repetition.

## Harness problems found (measurement only; no server code changed)

* **`tests/bench/joinbudget/storm.sql` cannot finish a storm on either tree** (done 0 of N after 1,500 ticks): its simulated clients never send `client_information`, so since the per-client view distance the server serves radius 3 (49 chunks) and the harness waits for 529.  A copy with the missing packet is `tools/scoreboard/storm_measured_storm.sql` (the paced runs above use it; `tests/bench` is untouched).  Not a server bug.
* **Planner statistics of the paced database**: the first paced run after the number of online players changed from 200 to 20 had 300-800 ms ticks (visibility 230-320 ms) until `vacuum analyze`; runs in the table above were not affected (same shape repeated, results cross-checked).
* `tools/scoreboard/run.py` is not executable (`python3` it); the harness additions of this work (`SCORE_STORM_PROF=1` function statistics, the game phases of the ten slowest ticks) are in `run.py`, the driver is `tools/scoreboard/storm_measured.sh` (setup, cell, vanilla; resumable), `storm_measured_chain.sh`, `storm_measured_paced.sh`.

## Reproduce

```
tools/scoreboard/storm_measured_chain.sh        # setup (BEFORE tree from `git archive f62f0f9` + its gateway, clusters in /dev/shm) and the cells, resumable
tools/scoreboard/storm_measured.sh vanilla 50   # vanilla, load below 3 (SCORE_XMS=1G SCORE_XMX=2G)
SCORE_STORM_PROF=1 tools/scoreboard/storm_measured.sh cell after 200 p0     # the profile run
tools/scoreboard/storm_measured_paced.sh 200 200 2
python3 tools/scoreboard/storm_measured_report.py; python3 tools/scoreboard/storm_measured_profile.py -rp
```
