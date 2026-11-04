# Scoreboard: dbcraft against the real vanilla 26.3 server

One campaign, one tree, one quiet machine.  Every number in this file and in [SCOREBOARD-table.md](SCOREBOARD-table.md) was measured in the same session (2026-11-04, about 7 hours of
wall time) on commit `f205b34` (every track merged: commands, survival, world dynamics, fills and terrain, disk compaction, login-storm budget, containers and crafting, mobs, the
vanilla player-visibility tracker, the idle/quiet tick, the urgent chat lane), against the real vanilla 26.3 jar (SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`).  Earlier numbers of
`docs/PERF-*.md`, taken in other sessions on loaded machines and older trees, are NOT used here; where this campaign disagrees with them it says so (last section).  The one-page summary is
[SCOREBOARD-SUMMARY.md](SCOREBOARD-SUMMARY.md); the previous scoreboard is kept as `SCOREBOARD-2026-11-02.md` with its raw data.

**Short answer.**  dbcraft is far cheaper than vanilla in memory (7-8 times), CPU (1.6-3 times with players online), world generation (12 times), disk (4 times), saving (no stall),
crash recovery (6.5 times, and a 1-second-old edit survives), the join of one player (3-6 times) and resting items (50 times); it is faster at bulk fills (4 times).
It is **not** faster where it matters for a busy server: with the supported defaults (survival core, vanilla tracker, world dynamics and containers on, simulation distance 10)
its tick is one single-threaded transaction that saturates one core at **200 walking players (99 ms mean tick, twice the 50 ms budget)**, at **500 players it cannot admit everybody**
(285-447 of 500 stayed connected to be measured; the gateway drops joiners that wait more than 30 s), the chat round trip at 50 players is 1.7-1.8 times vanilla's, the tail of a
200-join login storm is worse than vanilla's (worst tick 948 against 545 ms), and mobs that nobody can see cost 4-7 times vanilla's server thread.  Vanilla is not fine either:
at 200 walking players its main thread is so saturated that a chat takes 10 s (the probe's cap), at 500 players (crowded) its p99 tick is 2.1 s, and in the 10-minute soak it did not answer
RCON for the whole run; but nobody was disconnected and nobody was dropped.  Several of dbcraft's wins come from doing less work (list below): read them as "this cheaper design" and not as "the same server, faster".

## Method

* **Machine.**  One VM with 4 vCPUs and 15 GB (cgroup unlimited; /dev/shm 16 GB), Linux 6.18, **otherwise idle: no other agent or job ran** (checked with `uptime`).  **Before every run the runner waits
  until the 1-minute load average is at most 1.5 and records it**: the load at the start of the cells was 0.1 to 1.5 (the last column of the full table; the dbcraft cell that follows a vanilla cell
  starts at the top of that range because the average still contains the vanilla cell's own load).  The load generator runs on the same four cores (see "Limits").
* **vanilla**: the jar above, Java 25, G1, **`-Xms1G -Xmx2G`** (the container's cgroup OOM-killed vanilla JVMs at `-Xms2G` with 5,000 mobs in an earlier session; vanilla's PSS of 995 MiB at idle is mostly that 1 GB initial heap), fresh JVM for every run, flat world, offline,
  `network-compression-threshold=-1`, view distance 10, simulation distance 10, no mobs spawning.  The mobs rows use view distance 5 and simulation distance 10 on both sides.
* **dbcraft**: PostgreSQL 16 in a cluster of its own in `/dev/shm` (`tools/pg-dev.sh`: `fsync=off`, `synchronous_commit=off`, 128 MB shared buffers, `jit=off`), the **Rust gateway** built with `gateway/build.sh`, the default tick
  (`mc.server_tick()`), the database made by `tests/e2e/setup.sh`.  Defaults as shipped: survival core, `dbcraft.vanilla-tracker=true`, `dbcraft.dynamics=on` (scheduled ticks, fluids, falling blocks, random ticks), containers, recipes, the urgent chat
  lane, the quiet tick.  The harness (`tools/scoreboard/dbcraft.sh settings`) sets view distance 10, simulation distance 10, `max-players` 1000 and **`dbcraft.chunk-generation=async`** (the shipped default is `inline`; async is what the Rust gateway's two generator threads serve, like vanilla's worker threads).
  **`dbcraft.entity-mode` is `off` as shipped: dbcraft does not simulate mobs at all unless it is set to `inline` or `split`.**  The mobs rows therefore measure the entity tick that `inline` mode runs (`mc.entity_tick`), called directly, not the default server.
  The Postgres dev cluster has `fsync=off`: the crash rows measure a killed process (`kill -9` of the postmaster and every child at once), not a power cut.
* **Alternation and repetitions**: V D V D V D (three repetitions per cell, vanilla first), medians with [min-max].  A difference is a **TIE when the [min-max] ranges overlap**; otherwise the winner is named with the factor between the medians.  Three repetitions are a hint, not a confidence interval.
* **Players**: scripted clients (`tools/scoreboard/loadgen.py`, Python, 110 per process) that join, answer keep-alives and chunk batches, send `client_tick_end` every tick and walk at 4.3 blocks/s in random headings (bounded inside the pre-generated area).  They ask for view distance 10.
  Players are spread over 960 x 960 blocks (about 22 viewers each) unless a row says otherwise.  The world is **pre-generated** on both servers (the measurement is the tick, not generation), 60 s windows after every client has its chunks.  Chat p50/p99 is a probe client's
  round trip for its own chat message (about 60 per run; a value of 10,000 is the probe's 10 s cap: no reply).
* **Tick time**: vanilla's own `/tick query` (mean of the 100-tick windows over the run; p99 = median of the windows' p99); dbcraft: `ms_total` of `mc.server_tick_log`, every tick (the SQL tick; the gateway's loop around it is in the CPU).
* **CPU** = all threads of the server, cores used over the window: vanilla the JVM, dbcraft the Postgres process tree **plus the gateway process**.  **Memory** = PSS (shared memory counted once).  The load generator is excluded from both.
* **Edit rows**: nobody in range = no client; one viewer = a scripted client at the spawn.  "Statement" = vanilla RCON round trip / dbcraft server-side time of the SQL call in a warm session; "tick cost" = vanilla Server-thread CPU in the 0.6 s after the command minus its idle CPU /
  dbcraft sum of the logged ticks' `ms_total` in that window minus the idle mean.  dbcraft has no `/fill` command: the fill is `mc.fill()`, issued from SQL.
* **Mobs**: `tools/entity/vanilla_mobs.py` (cows with the default AI, RCON) against `tests/bench/mobs2/bench.sql` (100 measured entity ticks, one transaction per tick, on-CPU time).  Vanilla's cost is its Server thread's CPU per tick (cores x max(mean tick, 50 ms)).
* Raw results: `docs/scoreboard-results.jsonl.txt`, `docs/scoreboard-results-mobs.jsonl.txt`.  Everything that produced them is in `tools/scoreboard/` (`campaign.sh`, `mobs.sh`, `terrain.py`, `diag.sh`, `final_report.py`, `headline.py`).

## Headline table (medians [min-max] of 3 repetitions unless noted; ratio = dbcraft / vanilla, lower is better except where stated)

| Scenario | Metric | vanilla | dbcraft | ratio d/v | winner |
|---|---|---|---|---|---|
| idle, 0 players | tick mean (ms) | 0.350 [0.350-0.440] | 0.125 [0.113-0.139] | 0.36 | dbcraft (2.8x) |
| idle, 0 players | CPU (cores) | 0.018 [0.018-0.019] | 0.019 [0.019-0.019] | 1.01 | TIE |
| idle, 0 players | memory PSS (MiB) | 995 [988-1,007] | 118 [114-118] | 0.12 | dbcraft (8.4x) |
| idle, 50 players | tick mean (ms) | 44.0 [43.1-44.5] | 15.4 [14.4-27.6] | 0.35 | dbcraft (2.9x) |
| idle, 50 players | tick p99 (ms) | 77.0 [73.9-80.1] | 67.8 [62.5-155] | 0.88 | TIE |
| idle, 50 players | CPU (cores) | 1.10 [1.08-1.14] | 0.355 [0.330-0.592] | 0.32 | dbcraft (3.1x) |
| idle, 50 players | chat p50 (ms) | 31.2 [11.2-33.6] | 57.6 [55.2-105] | 1.84 | vanilla (1.8x) |
| idle, 50 players | chat p99 (ms) | 60.4 [59.3-68.6] | 88.9 [78.2-175] | 1.47 | vanilla (1.5x) |
| idle, 50 players | memory PSS (MiB) | 1,430 [1,383-1,470] | 209 [209-210] | 0.15 | dbcraft (6.8x) |
| idle, 200 players | tick mean (ms) | 69.0 [66.2-72.6] | 20.6 [20.2-22.3] | 0.30 | dbcraft (3.4x) |
| idle, 200 players | tick p99 (ms) | 119 [113-125] | 72.8 [69.9-76.3] | 0.61 | dbcraft (1.6x) |
| idle, 200 players | CPU (cores) | 1.47 [1.46-1.47] | 0.558 [0.544-0.591] | 0.38 | dbcraft (2.6x) |
| idle, 200 players | chat p50 (ms) | 43.2 [39.0-45.5] | 14.9 [13.6-28.3] | 0.34 | dbcraft (2.9x) |
| idle, 200 players | chat p99 (ms) | 89.4 [70.9-109] | 69.6 [48.1-101] | 0.78 | TIE |
| idle, 200 players | memory PSS (MiB) | 1,672 [1,643-1,704] | 215 [215-216] | 0.13 | dbcraft (7.8x) |
| 50 players all walking | tick mean (ms) | 61.6 [58.3-62.0] | 51.3 [49.0-54.9] | 0.83 | dbcraft (1.2x) |
| 50 players all walking | tick p99 (ms) | 102 [101-104] | 110 [103-117] | 1.07 | TIE |
| 50 players all walking | CPU (cores) | 1.53 [1.52-1.53] | 0.986 [0.984-0.994] | 0.64 | dbcraft (1.6x) |
| 50 players all walking | chat p50 (ms) | 51.1 [45.8-64.8] | 88.5 [88.1-96.1] | 1.73 | vanilla (1.7x) |
| 50 players all walking | chat p99 (ms) | 121 [89.4-177] | 208 [186-219] | 1.71 | vanilla (1.7x) |
| 200 players all walking | tick mean (ms) | 81.5 [78.7-88.5] | 98.7 [98.5-102] | 1.21 | vanilla (1.2x) |
| 200 players all walking | tick p99 (ms) | 799 [754-1,155] | 225 [194-341] | 0.28 | dbcraft (3.6x) |
| 200 players all walking | CPU (cores) | 1.89 [1.88-1.92] | 1.01 [1.01-1.01] | 0.54 | dbcraft (1.9x) |
| 200 players all walking | chat p50 (ms; 10,000 = the probe's cap, no reply) | 10,000 [10,000-10,000] | 185 [142-199] | 0.02 | dbcraft (54.2x) |
| 200 players all walking | chat p99 (ms) | 10,000 [10,000-10,000] | 307 [185-454] | 0.03 | dbcraft (32.6x) |
| 200 players, 20% walking | tick mean (ms) | 97.7 [96.6-98.1] | 39.9 [37.6-40.4] | 0.41 | dbcraft (2.4x) |
| 200 players, 20% walking | tick p99 (ms) | 173 [170-174] | 93.4 [90.4-97.0] | 0.54 | dbcraft (1.9x) |
| 200 players, 20% walking | CPU (cores) | 1.87 [1.80-1.91] | 0.955 [0.929-0.969] | 0.51 | dbcraft (2.0x) |
| 200 players, 20% walking | chat p50 (ms) | 177 [55.9-362] | 81.2 [69.9-85.4] | 0.46 | TIE |
| 200 players, 20% walking | chat p99 (ms) | 943 [407-1,189] | 153 [152-200] | 0.16 | dbcraft (6.2x) |
| login storm: 50 joins in 1 s into 20 online | all joined, all chunks (s) | 44.4 [43.9-44.7] | 8.04 [7.78-8.29] | 0.18 | dbcraft (5.5x) |
| login storm: 50 joins in 1 s into 20 online | worst tick (ms) | 166 [121-171] | 165 [154-165] | 1.00 | TIE |
| login storm: 50 joins in 1 s into 20 online | tick p99 (ms) | 89.7 [84.2-94.6] | 161 [152-164] | 1.79 | vanilla (1.8x) |
| login storm: 50 joins in 1 s into 20 online | online players' chat p50 (ms) | 27.8 [26.6-31.0] | 146 [137-149] | 5.26 | vanilla (5.3x) |
| login storm: 50 joins in 1 s into 20 online | online players' chat p99 (ms) | 252 [236-360] | 262 [230-275] | 1.04 | TIE |
| login storm: 200 joins in 1 s into 20 online | all joined, all chunks (s) | 51.8 [51.6-53.1] | 39.9 [39.7-40.2] | 0.77 | dbcraft (1.3x) |
| login storm: 200 joins in 1 s into 20 online | worst tick (ms) | 545 [451-621] | 948 [908-958] | 1.74 | vanilla (1.7x) |
| login storm: 200 joins in 1 s into 20 online | tick p99 (ms) | 120 [120-127] | 265 [241-273] | 2.20 | vanilla (2.2x) |
| login storm: 200 joins in 1 s into 20 online | online players' chat p50 (ms) | 182 [142-188] | 216 [210-217] | 1.18 | vanilla (1.2x) |
| login storm: 200 joins in 1 s into 20 online | online players' chat p99 (ms) | 2,408 [2,267-2,737] | 419 [398-1,119] | 0.17 | dbcraft (5.7x) |
| one joiner, view distance 10 | unexplored world, all chunks (s) | 4.16 [3.99-4.22] | 0.687 [0.687-0.700] | 0.17 | dbcraft (6.1x) |
| one joiner, view distance 10 | explored world, all chunks (s) | 1.55 [1.48-1.60] | 0.527 [0.525-0.550] | 0.34 | dbcraft (2.9x) |
| edits, nobody in range | single block edit, statement (ms) | 2.66 [2.45-2.92] | 3.90 [3.63-4.04] | 1.46 | vanilla (1.5x) |
| edits, nobody in range | fill 1,000, statement (ms) | 11.4 [11.0-13.0] | 5.90 [5.01-6.38] | 0.52 | dbcraft (1.9x) |
| edits, nobody in range | fill 1,000, tick cost (ms) | 10.1 [9.11-12.1] | 0.819 [0.000-2.85] | 0.08 | dbcraft (12.4x) |
| edits, nobody in range | fill 100,000, statement (ms) | 267 [266-325] | 71.1 [63.0-83.8] | 0.27 | dbcraft (3.8x) |
| edits, nobody in range | fill 100,000, tick cost (ms) | 245 [219-313] | 0.892 [0.000-1.10] | 0.00 | dbcraft (275.2x) |
| edits, one viewer in range | single block edit, statement (ms) | 2.78 [2.61-2.88] | 3.42 [2.93-3.57] | 1.23 | vanilla (1.2x) |
| edits, one viewer in range | single block edit, tick cost (ms) | 0.000 [0.000-0.113] | 17.2 [3.11-35.0] |  | vanilla |
| edits, one viewer in range | fill 1,000, statement (ms) | 16.3 [11.1-17.6] | 5.38 [4.74-6.40] | 0.33 | dbcraft (3.0x) |
| edits, one viewer in range | fill 1,000, tick cost (ms) | 19.4 [12.8-27.8] | 79.9 [59.7-90.3] | 4.13 | vanilla (4.1x) |
| edits, one viewer in range | fill 100,000, statement (ms) | 344 [320-389] | 76.1 [72.4-79.9] | 0.22 | dbcraft (4.5x) |
| edits, one viewer in range | fill 100,000, tick cost (ms) | 352 [345-429] | 297 [290-391] | 0.84 | TIE |
| admin edit path, nobody in range | single edits per second | 995 [945-1,050] | 2,911 [2,738-3,004] | 2.93 | dbcraft (2.9x) |
| 10,000-chunk flat world | generation (s) | 26.0 [25.8-27.1] | 2.08 [1.84-2.32] | 0.08 | dbcraft (12.5x) |
| 10,000-chunk flat world | size after save (MiB) | 62.1 [62.1-62.1] | 14.9 [14.9-14.9] | 0.24 | dbcraft (4.2x) |
| 10,000-chunk flat world | save stall (s) | 6.01 [5.64-7.84] | 0.068 [0.067-0.074] | 0.01 | dbcraft (88.4x) |
| 10,000-chunk flat world | kill -9 to accepting logins (s) | 14.8 [14.8-15.8] | 2.27 [2.10-2.71] | 0.15 | dbcraft (6.5x) |
| 10,000-chunk flat world | edit 1 s old, never saved, survives kill -9 (1 = yes) | 0.000 [0.000-0.000] | 1.00 [1.00-1.00] |  | dbcraft |
| terrain generation, 64 x 64 chunks (NOT like for like) | CPU per chunk (ms), not like for like | 74.3 [72.1-77.5] | 8.24 [7.96-8.44] | 0.11 | dbcraft (9.0x) |
| 10-minute soak, 200 walking players | CPU (cores) | 1.66 [1.65-1.66] | 1.00 [1.00-1.00] | 0.61 | dbcraft (1.7x) |
| 10-minute soak, 200 walking players | clients dropped | 0.000 [0.000-0.000] | 0.000 [0.000-0.000] |  | TIE |
| 10-minute soak, 200 walking players | chat p50 (ms) | 10,000 [10,000-10,000] | 202 [191-214] | 0.02 | dbcraft (49.4x) |
| 10-minute soak, 200 walking players | tick mean (ms) | no usable samples | 108 [102-114] |  | - |
| 10-minute soak, 200 walking players | tick p99 (ms) | no usable samples | 331 [294-367] |  | - |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | tick mean (ms) | 135 [121-145] | 446 [301-750] | 3.30 | vanilla (3.3x) |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | tick p99 (ms) | 2,126 [1,773-2,590] | 905 [490-1,042] | 0.43 | dbcraft (2.3x) |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | clients dropped (of 500) | 0.000 [0.000-0.000] | 168 [103-240] |  | vanilla |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | clients in play when measured (of 500) | 500 [497-500] | 353 [285-407] | 0.71 | vanilla (1.4x) |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | chat p50 (ms) | 10,000 [10,000-10,000] | 748 [470-970] | 0.07 | dbcraft (13.4x) |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | CPU (cores) | 2.02 [1.99-2.09] | 1.01 [1.01-1.02] | 0.50 | dbcraft (2.0x) |
| 500 players over 100 x 100 chunks, all moving (dbcraft only) | tick mean (ms) | not run | 279 [260-284] |  | - |
| 500 players over 100 x 100 chunks, all moving (dbcraft only) | tick p99 (ms) | not run | 422 [417-455] |  | - |
| 500 players over 100 x 100 chunks, all moving (dbcraft only) | clients dropped (of 500) | not run | 82.0 [70.0-141] |  | - |
| 500 players over 100 x 100 chunks, all moving (dbcraft only) | chat p50 (ms) | not run | 430 [373-496] |  | - |
| 500 players over 100 x 100 chunks, 20% moving (dbcraft only) | tick mean (ms) | not run | 58.3 [52.5-59.4] |  | - |
| 500 players over 100 x 100 chunks, 20% moving (dbcraft only) | tick p99 (ms) | not run | 116 [104-124] |  | - |
| 500 players over 100 x 100 chunks, 20% moving (dbcraft only) | clients dropped (of 500) | not run | 118 [82.0-132] |  | - |
| 500 players over 100 x 100 chunks, 20% moving (dbcraft only) | chat p50 (ms) | not run | 127 [111-143] |  | - |
| mobs: 500 awake cows, viewer in range | entity tick CPU per tick (ms; vanilla: Server thread) | 16.0 [15.0-16.9] | 13.0 [12.0-14.1] | 0.81 | dbcraft (1.2x) |
| mobs: 2,000 awake cows, viewer in range | entity tick CPU per tick (ms; vanilla: Server thread) | 60.8 [57.4-63.3] | 33.2 [31.0-34.0] | 0.55 | dbcraft (1.8x) |
| mobs: 5,000 awake cows, viewer in range | entity tick CPU per tick (ms; vanilla: Server thread) | 149 [138-161] | 70.5 [69.3-78.2] | 0.47 | dbcraft (2.1x) |
| mobs: 500 awake cows, nobody in range | entity tick CPU per tick (ms; vanilla: Server thread) | 4.10 [4.05-4.45] | 15.5 [12.7-18.7] | 3.78 | vanilla (3.8x) |
| mobs: 2,000 awake cows, nobody in range | entity tick CPU per tick (ms; vanilla: Server thread) | 5.95 [5.85-6.15] | 33.9 [33.3-38.6] | 5.69 | vanilla (5.7x) |
| mobs: 5,000 awake cows, nobody in range | entity tick CPU per tick (ms; vanilla: Server thread) | 11.5 [10.3-11.7] | 76.1 [68.3-78.4] | 6.62 | vanilla (6.6x) |
| mobs: 5,000 resting items, viewer in range | entity tick CPU per tick (ms; vanilla: Server thread) | 72.2 [66.1-73.6] | 1.40 [1.33-2.21] | 0.02 | dbcraft (51.6x) |

(Rows with "dbcraft only" were not run on vanilla: see the crowded-spawn paragraph.  Soak, 2 repetitions each.  Every row is in [SCOREBOARD-table.md](SCOREBOARD-table.md) with its load average; the row for walking 20% moving and the 500-player rows are there in full.)

## Where dbcraft loses (ranked by how much it matters in real play)

1. **Moving-player capacity: one core, and it is saturated at 200.**  The tick is one transaction on one core: dbcraft's CPU is 1.00 cores in every walking cell of 50 or more players; the SQL tick at **200 all-walking players is 98.7 [98.5-102] ms**, vanilla's 81.5 [78.7-88.5] ms
   (**vanilla 1.2 times better on the mean**, TIE neither under 50 ms; dbcraft's p99 is 3.6 times better: 225 against 799 ms; vanilla uses 1.9 cores).  50 all-walking players: 51 against 62 ms (dbcraft 1.2 times better), p99 TIE.  With 20% walking, dbcraft is clearly better (40 against 98 ms).
   **500 players**: the gateway closes connections that sit more than 30 s without a byte (`connection N dropped: read timeout (no bytes)` in its log, about 100 of them at the 50 s mark of a crowded run; most likely joins that the join budget held back, inferred from the timing and not proven); in the crowded-spawn runs **103-240 of 500 clients were dropped and only 285-407 were in play when the window started**, 70-141 dropped and 385-447 in play for the sparse all-moving runs, 82-132 dropped and 390-443 in play for 20% moving.
   Even with those missing players the tick was **446 [301-750] ms (crowded, all moving; vanilla 135 [121-145] ms with all 500 in, p99 2.1 s)**, **279 [260-284] ms sparse all moving**, **58 [53-59] ms sparse with 20% moving** (p99 116 ms).  Not 50 ms in any of them.  Vanilla at 500 crowded holds everybody and averages 135 ms with a 2.1 s p99; both fail the 50 ms budget, dbcraft by more and with players lost.
2. **Chat latency and tick spikes with a few dozen players: random ticks at simulation distance 10.**  With 50 idle players chat p50/p99 is **58 / 89 ms against vanilla's 31 / 60** (vanilla 1.8 / 1.5 times better), 50 walking players 88 / 208 against 51 / 121 (1.7 times).  The cause was found by diagnosis
   (`tools/scoreboard/diag.sh`, the same cells with `dbcraft.dynamics=off`): every 4th tick costs about 100 ms (every other tick 3-5 ms) because the random-tick pass (`dbcraft.random-tick-interval` 4, `random-tick-chunk-budget` 4) walks whole simulation areas of players at simulation distance 10 (441 chunks each) on that tick; with dynamics off the 50-idle tick mean is 5.7 ms instead of 15.4,
   the p99 16 ms instead of 68, the CPU 0.18 instead of 0.36 cores and the chat p50 14 ms.  Dynamics at 200 idle players: 20.6 -> 12.8 ms.  **It does not change the 200-walker tick** (98.7 against 105 ms with dynamics off).  Hardly any of the random ticks do anything on a flat grass world.  Closing it is the best single improvement still open.
3. **Login storms: the tail.**  50 joins into 20 online: the online players' chat p50 during the storm is **146 ms against 28** (vanilla 5.3 times better), tick p99 161 against 90 ms; worst tick TIE (165 / 166 ms).  200 joins: worst tick **948 [908-958] against 545 [451-621] ms**, tick p99 265 against 120 ms, chat p50 216 against 182 ms (vanilla 1.2 times better).
   dbcraft wins the time until everybody is in with all chunks (8.0 against 44.4 s at 50 joins, 39.9 against 51.8 s at 200) and the chat p99 / max of the players already online at 200 joins (419 against 2,408 ms), and nobody was dropped in either storm on either server.
   **Update after this campaign** ([PERF-STORM.md](PERF-STORM.md), round 2; a shared machine at load 1.6-5, old and new code alternated, 3 repetitions, vanilla one repetition): the worst tick at 200 joins 899 -> **257 ms** (the 120-player locator-bar cap crossing and the waypoint packet cost), tick p99 261 -> 205 ms, online chat p50 205 -> 64 ms; at 50 joins online chat p50 153 -> **53 ms** (the urgent lane runs before a late tick), p99 295 -> 129.
   Still behind vanilla's campaign figures on the tick p99 at 200 joins (205 against 120 ms) and the chat p50 at 50 joins (53 against 28 ms).
4. **Mobs that nobody can see, and mobs by default.**  500 / 2,000 / 5,000 awake cows with nobody in range: **15.5 / 33.9 / 76 ms against vanilla's 4.1 / 6.0 / 11.5 ms of Server thread CPU (3.8 / 5.7 / 6.6 times worse)**
   on the tree of this campaign.  **Follow-up (docs/PERF-MOBS2.md part 2, re-measured V D V D V D with vanilla `-Xms1G -Xmx2G` at load 3-7, 3 repetitions): the simulation distance was not the cause** (3 against 10: 12.0 / 13.1 against
   11.1 / 10.9 ms at 2,000 cows in view); the mob rows had run on the database the edit scenario had just littered with 2,000 blocks, and a mob without a floor-uniform walk gets no lane (250-300 us a tick; 215-238 ms for
   2,000 cows in view on such ground, 10 on flat ground; `tools/scoreboard/mobs.sh` now regenerates the area, `bench.sql -v reset=1`).  **Lazy lanes** (lanes nobody can see are replayed in closed form every 32nd tick, equal to the
   tick-by-tick run on random lanes) bring cows nobody can see to **1.4 / 4.2 / 7.5 ms with nobody connected (vanilla 5.0 / 6.6 / 10.5 in the same alternation: dbcraft 0.28 / 0.64 / 0.71 of vanilla)** and to **3.5 / 8.2 / 13.2 ms with a
   viewer connected whose view ends before the cows (0.71 / 1.24 / 1.25 of vanilla: still a loss at 2,000 and 5,000)**; in view 9.5 / 20.6 ms against vanilla's 81.5 / 195 at 2,000 / 5,000.  And `dbcraft.entity-mode` is `off`: the default server has no mobs;
   measured with no mobs at all, `inline` costs 0.5-2 ms a tick (0 to 200 players) and defeats the quiet tick, so it stays off (PERF-MOBS2 part 2, section 5).
5. **Edits with a viewer in range.**  A single `setblock` is 2.66 ms for vanilla and **3.90 ms** for dbcraft's `mc.set_block` through psql (vanilla 1.5 times better with nobody in range, 1.2 times with a viewer; not the dynamics engine: it is 4.2 ms with dynamics off).  With a viewer a 1,000-block fill costs the **tick 79.9 [59.7-90.3] ms against vanilla's 19.4 [12.8-27.8]**
   (vanilla 4.1 times better; with dynamics off 4.7 ms: it is the dynamics engine processing the fill), and a 100,000-block fill 297 [290-391] ms against 352 [345-429] ms: a TIE (with dynamics off: 6.5 ms).  The single-edit tick cost with a viewer (17 ms mean, 3-35) is dominated by the 4-tick random-tick pattern (1.4 ms with dynamics off).

## Where it wins

* **Memory: 7-8 times less** (118 MiB empty, 209-229 MiB with 50-500 players, against vanilla's 995 / 1,400-1,800 MiB; vanilla's figure is partly its 1 GB initial heap).
* **CPU with players online: 1.6-3.1 times less** (50 idle 0.36 against 1.10 cores; 200 idle 0.56 against 1.47; 200 walking 1.01 against 1.89), and **idle tick 2.8-3.4 times shorter** (0.125 against 0.35 ms empty; 20.6 against 69 ms at 200 idle).  Idle 0-player CPU is a tie (0.019 against 0.018).
* **Overload behaves better**: at 200 walking players vanilla's chat round trip is the 10 s cap (never answered) and its RCON did not answer for 10 minutes; dbcraft's chat p50 is 185 ms (200 walking) and 202 ms over the 10-minute soak, **and not one of the 200 clients was dropped in the soak** (the gateway-loop degradation of the PL/Python era is gone).
  With 20% walking, dbcraft's chat p99 is 153 against 943 ms.
* **Joining**: one joiner into an unexplored world 0.69 against 4.16 s (6.1 times), into an explored one 0.53 against 1.55 s (2.9 times); a 50-join storm until everybody has every chunk 8.0 against 44.4 s (5.5 times).
* **Persistence and disk**: generating 10,000 flat chunks 2.08 against 26.0 s (12.5 times); the world is **14.9 MiB against 62.1 MiB** (4.2 times smaller; dbcraft = sum of the world tables, vanilla = the world folder); saving: `CHECKPOINT` 0.068 s against `save-all flush` 6.0 s (88 times; dbcraft's checkpoint is a background process, vanilla's flush blocks);
  `kill -9` to accepting logins 2.3 against 14.8 s (6.5 times), **an edit made 1 s before the kill survives in dbcraft (3 of 3) and is lost in vanilla (0 of 3)**; an edit saved before the kill survives on both.  (`fsync=off`: process crash only.)
* **Bulk edits**: a 100,000-block fill 71 against 267 ms (3.8 times) with nobody in range and 76 against 344 ms with a viewer, and with nobody in range the tick pays 0.9 ms against vanilla's 245 ms; 1,000 blocks 5.9 against 11.4 ms.  The admin path (many single edits through one SQL session against RCON): 2,911 against 995 edits per second (2.9 times).
* **Terrain generation per chunk**: 8.2 against 74.3 ms of CPU (whole process tree, 4,096 chunks, 9 times) **but see "not comparable"**.
* **Resting items**: 5,000 items at rest cost the entity tick 1.4 ms against 72 ms of vanilla's Server thread (52 times); awake mobs **in view**: 500 / 2,000 / 5,000 cows 13 / 33 / 71 ms against 16 / 61 / 149 ms (1.2 / 1.8 / 2.1 times).
* A 50-player walking server's mean tick (51 against 62 ms), a 200-player 20%-walking server (40 against 98 ms, CPU 0.96 against 1.87) and the idle 200-player server.

**Ties** (ranges overlap): idle 0-player CPU (0.019 / 0.018 cores), idle 50-player tick p99 (68 / 77 ms), idle 200-player chat p99 (70 / 89 ms), 50-walker tick p99 (110 / 102 ms), 200-walker 20% chat p50 (81 [70-85] / 177 [56-362] ms: the ratio is 0.46 but vanilla's range is wide), 50-join storm worst tick (165 / 166 ms)
and online chat p99 (262 / 252 ms), the 100,000-block fill's tick cost with a viewer (297 / 352 ms), and every "clients dropped" count of 0 (50 and 200 idle and walking, storms, soak).

## What is NOT comparable, and what dbcraft does NOT do that vanilla does (read before quoting any ratio)

* **Everywhere**: dbcraft is a flat world (the optional `dbcraft:noise` terrain has 16 biomes), **no light engine** (straight-down sky light, no block light, no light updates after edits), **no mobs by default, no pathfinding, no goals/AI, no collision with entities, no redstone, no leaf decay, tree growth or shape updates (fences do not connect), no item drops from broken blocks, about 70 of vanilla's 90 commands answer "not implemented", no advancements/recipes generation (replayed from a capture), no chat signing and offline mode only for real clients, no structures, no sounds,
  no armor, potions, fire, drowning, beds.**  It does have a survival core (health, hunger, fall/void damage, death, respawn, regeneration, eating, experience), vanilla's player tracker, chests/barrels/furnaces/crafting, fluids, falling blocks and random ticks (compared packet for packet with vanilla in the tests).  Vanilla does all of it, so a tick of vanilla contains work dbcraft's does not.
* **Idle and walking rows** (50-200 players): vanilla's tick is dominated by per-chunk and per-player work (chunk map, entity tracking, light engine, chunk ticking, packet encoding per player), the same view distance and tracker rules apply on both sides; dbcraft sends cached chunk packets and does no light work, which is where most of its CPU and memory advantage comes from.  The scripted players do not inventory-click, place blocks or chat except the probe.
* **Login storms**: dbcraft's 8.0 s against 44.4 s is largely cached chunk packets against vanilla's per-chunk serialization and light; vanilla also runs its configuration phase from the real registries, dbcraft replays a capture.
* **Edits**: dbcraft's `mc.set_block` / `mc.fill` skip lighting and vanilla's block-update and neighbour-shape cascades (dynamics covers fluids, gravity and support only); the 100,000-block fill with nobody in range shows **0.9 ms of tick against 245 ms** because dbcraft's broadcast waits for a viewer.  dbcraft has no `/fill` command; the vanilla number is an RCON round trip, the dbcraft number a psql statement.
* **World generation, size, save, crash**: the flat chunk of dbcraft is a few rows; vanilla also writes entities, POI and heightmaps in 4 KiB sectors (in the earlier session it wrote 15,876 chunk entries for the 10,000 chunks, the unfinished border chunks included).  The size row compares `sum(pg_total_relation_size)` of five world tables with `du -sb world/`.  Vanilla's `save-all flush` is the worst case (10,000 loaded dirty chunks); a real server saves incrementally.  The crash rows run with `fsync=off`.
* **Terrain**: **not like for like.**  vanilla builds real terrain (caves, ores, trees, structures, its light); dbcraft's `dbcraft:noise` is seeded height noise with biomes, bedrock and sea level, no caves, ores, trees or structures, straight-down light.  The 9-fold CPU ratio compares different work.
* **Mobs**: dbcraft models no pathfinding, goals, look-around, motion packets, sounds or collision; its cows wander more (45%) than vanilla's (about 24%).  Vanilla's number is a thread's CPU, dbcraft's an on-CPU backend time of the SQL entity tick; both pay on the main path.  The viewer-less mobs are a loss because dbcraft's entities are rows updated through SQL.
* **Memory**: PSS of a JVM with a 1 GB initial heap against a process tree with 128 MB shared buffers; vanilla's need is lower than its 995 MiB at idle, and dbcraft's database also keeps the world on disk and in the OS page cache, which PSS does not count.
* **Chat round trips** come from one probe client per run and about 60 samples; a 10,000 ms value is the probe's cap.
* **The soak**: vanilla's `tick query` answered once in the ten minutes (26 polls timed out at 20 s) so its tick statistics are not usable; its CPU, chat and the absence of drops are.  dbcraft's tick log keeps the last 6,001 ticks, so its tick statistics cover the last 5 minutes.

## Diagnosis: what the dynamics cost (dbcraft with `dbcraft.dynamics = off`, a diagnosis, not a supported configuration)

| cell | metric | dynamics on (campaign) | dynamics off | reps on/off |
|---|---|---|---|---|
| idle, 50 players | tick mean (ms) | 15.4 [14.4-27.6] | 5.67 [5.56-5.79] | 3/2 |
| idle, 50 players | tick p99 (ms) | 67.8 [62.5-155] | 15.8 [13.4-18.3] | 3/2 |
| idle, 50 players | CPU (cores) | 0.355 [0.330-0.592] | 0.176 [0.171-0.180] | 3/2 |
| idle, 50 players | chat p50 (ms) | 57.6 [55.2-105] | 14.0 [8.07-20.0] | 3/2 |
| idle, 200 players | tick mean (ms) | 20.6 [20.2-22.3] | 12.8 [11.8-13.9] | 3/2 |
| idle, 200 players | tick p99 (ms) | 72.8 [69.9-76.3] | 25.9 [23.5-28.4] | 3/2 |
| idle, 200 players | CPU (cores) | 0.558 [0.544-0.591] | 0.410 [0.384-0.436] | 3/2 |
| idle, 200 players | chat p50 (ms) | 14.9 [13.6-28.3] | 25.1 [19.5-30.6] | 3/2 |
| 200 players all walking | tick mean (ms) | 98.7 [98.5-102] | 105 [97.8-111] | 3/2 |
| 200 players all walking | tick p99 (ms) | 225 [194-341] | 441 [393-488] | 3/2 |
| 200 players all walking | CPU (cores) | 1.01 [1.01-1.01] | 1.01 [1.01-1.01] | 3/2 |
| 200 players all walking | chat p50 (ms) | 185 [142-199] | 283 [201-365] | 3/2 |
| edits, one viewer | single edit statement p50 (ms) | 3.42 [2.93-3.57] | 4.24 [4.01-4.46] | 3/2 |
| edits, one viewer | single edit tick cost (ms) | 17.2 [3.11-35.0] | 1.36 [1.20-1.51] | 3/2 |
| edits, one viewer | fill 1,000 tick cost (ms) | 79.9 [59.7-90.3] | 4.70 [2.96-6.44] | 3/2 |
| edits, one viewer | fill 100,000 statement p50 (ms) | 76.1 [72.4-79.9] | 122 [120-124] | 3/2 |
| edits, one viewer | fill 100,000 tick cost (ms) | 297 [290-391] | 6.48 [6.36-6.61] | 3/2 |

## Limits of this campaign, and what could not be run

* **The load generator shares the four cores.**  At 200 players it is two Python processes, at 500 players five; the load average of the 500-player cells reached 5-8 while they ran (one reading of 7.9 during a vanilla cell).  Both servers are disturbed by it (vanilla, which can use all cores, more in absolute CPU terms; dbcraft's single tick thread when it is descheduled).  The 500-player numbers are the least reliable of the campaign:
  the dbcraft runs additionally lost 70-240 of the 500 clients (gateway read timeout while waiting in the join queue, `connection N dropped: read timeout (no bytes)` in the gateway log, plus write errors after the clients gave up), so their tick statistics describe 285-447 players.  Whether the drops are the join budget or the starved load generator was not separated.
  **Vanilla was run at 500 in the crowded case only; the sparse 500-player cells are dbcraft only** (the task: dbcraft with tracker on).
* **First soak attempt discarded**: the vanilla 10-minute soak aborted after 465 s because a blocking RCON call had no timeout (`TimeoutError`, 300 s); the runner now polls with a 20 s timeout and counts the misses (`rcon_timeouts`).  The record is kept in `docs/scoreboard-results.jsonl.txt` under the tag `soak-attempt1-harness-bug`.  The soak ran twice per server, not three times.
* Block-edit "tick cost" for dbcraft is a sum of logged ticks minus an idle mean, so it has noise of a few ms and for single edits is dominated by the random-tick pattern; vanilla's is a thread-CPU difference with the same window.  The 1,000-block and 100,000-block viewer rows are well outside that noise.
* The dev cluster has `fsync=off`, so the crash rows measure a killed process; no power-cut test was run, and no fsync-on rerun of the persistence rows was made.
* Vanilla is the real 26.3 server, but its flat-world chunk work, view distance 10 and 4 vCPUs are the only configuration measured: no structures, no mobs spawning, no redstone, no real clients (scripted ones; the real-client flow is tested separately in `docs/REAL-CLIENT.md`), no online mode.
* Not run: 2,000 players (the load generator cannot drive them), crowded spawn at 500 with 20% moving, vanilla in the sparse 500-player cells, a power-cut test, online-mode joins.

## Harness bugs found and fixed while measuring

* `run.py` had no load gate: added `--load-max` / `SCORE_LOAD_MAX` (wait until the 1-minute load average is at most 1.5, record it).
* `vanilla.sh` used one heap size for `-Xms` and `-Xmx`: `SCORE_XMS` / `SCORE_XMX` added (this campaign 1G / 2G).
* A blocking RCON poll made a saturated vanilla fail a whole 10-minute cell (see above): polls now time out after 20 s, are counted, and reconnect.
* The new `edit` scenario (`run2.py`) replaces the block-edit harness that timed a fresh `psql` per statement: a cold backend adds 20 ms to the first `set_block`, so the statements are timed in one warm session, the tick cost is measured, and the viewer is a real client through the gateway instead of a fake connection row.
* `tools/entity/vanilla_mobs.py` was used as is; `terrain.py` wraps `vanilla_gen.py` / `gen_cluster.py` of PERF-WORLD2 (they hardcoded a scratch directory, now `/dev/shm/sb/dbc-world2-vanilla`).

## Where this campaign disagrees with the earlier documents

* **Idle with players, the Rust gateway** (PERF-IDLE2: 50 idle 3.1 ms tick, 0.114 cores, chat 8 ms; 200 idle 5.0 ms): this tree measures 15.4 ms / 0.36 cores / 58 ms and 20.6 ms.  The tracker, survival, containers and dynamics merged since then; the diagnosis above attributes 10 of the 15 ms (50 players) to dynamics' random ticks at simulation distance 10.
* **Fills with a viewer** (PERF-WORLD2: tick 3-9 ms after a 100,000-block fill): 297 ms here, with a real client through the gateway; 6.5 ms with dynamics off.  **Mobs in view** (PERF-MOBS2: 10.9 ms at 2,000 cows): 33 ms here (11.0 ms reproduced at simulation distance 3, but also at 10 on fresh ground: the cause is the 2,000 blocks of the edit scenario on the ground of the mob rows, docs/PERF-MOBS2.md part 2).
* **The 200-walker soak** (the old scoreboard's first loss, all clients timed out after about 4 minutes with the PL/Python gateway): **gone** with the Rust gateway; 0 of 200 dropped over 10 minutes, twice.
* **Single block edit** (0.11-0.16 ms in the old rows) is 3.4-3.9 ms through a fresh `psql` timing here with the dynamics engine in the path; the admin-path scenario (`blocks`) measures 0.20 ms per edit in a warm loop.

## Reproduce

```
tools/scoreboard/cenv tools/scoreboard/dbcraft.sh setup-db          # own cluster in /dev/shm/sb (cenv sets every port and path), gateway/build.sh first
tools/scoreboard/cenv tools/scoreboard/campaign.sh idle walk storm misc crowd soak      # the load gate, V D V D, results in /dev/shm/sb/out/results.jsonl
tools/scoreboard/cenv python3 tools/scoreboard/terrain.py --size 64 --reps 3
tools/scoreboard/cenv tools/scoreboard/mobs.sh /dev/shm/sb/mobs 3
tools/scoreboard/cenv tools/scoreboard/diag.sh                       # dynamics off
tools/scoreboard/cenv python3 tools/scoreboard/make_final_docs.py    # SCOREBOARD-table.md and the raw files;  headline.py prints the headline table
```
Needs the vanilla jar at `~/.cache/dbcraft/server-26.3.jar` (`tools/fetch_jar.py`), Java 25, PostgreSQL 16 with plpython3u, the generator reports.
