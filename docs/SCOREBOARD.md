# Scoreboard: dbcraft against the real vanilla 26.3 server (final campaign)

Second campaign, run on the FINAL tree (main at `400f628`: dynamics fixes, storm round 2, mobs phase 2, idle track 2, the capacity track), against the real vanilla 26.3 jar (SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`).  It replaces the first campaign (`SCOREBOARD-2026-11-04-campaign1.md`, tree `f205b34`), whose files are kept with that date suffix.

**Campaign state at this commit: 26 runs on the final tree are in the raw results; 62 headline rows below were NOT re-run on the final tree and are shown in italics with the previous campaign's values (older tree, different VM).**

**The virtual machine is not the one of campaign 1.**  The container was restarted during this campaign and came back on a faster host: vanilla's own idle-50 tick fell from 44 to
24 ms and its idle 0 tick from 0.35 to 0.27 ms with no change in the jar.  So a dbcraft number "before -> after" mixes the tree and the machine; read the **ratio dbcraft / vanilla** columns of the
"what changed" table (vanilla is the control), not the absolute milliseconds.

## Method (as in campaign 1, with the differences listed)

* One VM, 4 vCPUs, 15 GB, nothing else running; **before every run the runner waits for the 1-minute load average to be at most 1.5 and records it** (last column of the full table).
* **vanilla**: the jar above, Java 25, G1, **`-Xms1G -Xmx2G`**, fresh JVM per run, flat world, offline, no compression, view distance 10, simulation distance 10, nothing spawning.
* **dbcraft**: PostgreSQL 16 in a cluster of its own in `/dev/shm` (`tools/pg-dev.sh`: `fsync=off`, `synchronous_commit=off`, 128 MB shared buffers, `jit=off`), the Rust gateway built by `gateway/build.sh`, the default
  tick (`mc.server_tick()`), database from `tests/e2e/setup.sh`; survival core, `dbcraft.vanilla-tracker=true`, `dbcraft.dynamics=on`, containers, quiet tick and urgent chat lane as shipped; the harness sets view and simulation
  distance 10, `max-players` 1000 and `dbcraft.chunk-generation=async` (shipped: inline).  `dbcraft.entity-mode` is `off` as shipped (no mobs are simulated): the mobs rows measure the inline entity tick, called directly.
  `fsync=off` means the crash rows measure a killed process, not a power cut.
* **V D V D V D**, three repetitions per cell (soak: two), medians with [min-max]; a difference is a **TIE when the [min-max] ranges overlap**.  Three repetitions are a hint, not a confidence interval.
* Players are the scripted clients of `tools/scoreboard/loadgen.py` (Python, 110 per process; they join, answer keep-alives, send `client_tick_end` every tick, walk at 4.3 blocks/s in random headings inside the pre-generated area),
  spread over 960 x 960 blocks, 60 s windows on a pre-generated world; chat p50/p99 is a probe client's round trip (10,000 = its 10 s cap: no reply).  **The load generator shares the four cores with the server.**  For the 500-player cells the
  runner records the load generator's own CPU and the whole machine's busy cores over the window (rows "load generator CPU", "whole machine busy").
* Tick time: vanilla's `/tick query`; dbcraft's `ms_total` of `mc.server_tick_log` (the SQL tick).  CPU: all threads of the server (dbcraft: Postgres process tree **plus the gateway process**); memory: PSS.
* Edits: "statement" = vanilla RCON round trip / dbcraft server-side time of the SQL call in a warm session; "tick cost" = vanilla Server-thread CPU in the 0.6 s after the command minus idle / dbcraft sum of the logged ticks minus
  the idle mean.  Mobs: `tools/entity/vanilla_mobs.py` against `tests/bench/mobs2/bench.sql` with **`reset=1`** (the mob area is regenerated flat first: campaign 1's in-view mob rows were inflated by a world that the edit scenario had scribbled in),
  vanilla = Server-thread CPU per tick, dbcraft = on-CPU time of the entity tick; "nobody connected" is dbcraft with no player at all (vanilla has no equivalent: with nobody connected it does not tick its entities, so its figure for those rows is the viewer-away ring).
* Raw results: `docs/final-campaign/results.jsonl` (copied to `docs/scoreboard-results.jsonl.txt`), `docs/final-campaign/mobs/`.  Runners are resumable and results are committed during the run (`tools/scoreboard/resume.sh`, `checkpoint.sh`).

## Headline table (medians [min-max]; ratio = dbcraft / vanilla, lower is better except where stated)

| Scenario | Metric | vanilla | dbcraft | ratio d/v | winner |
|---|---|---|---|---|---|
| idle, 0 players | tick mean (ms) | 0.270 [0.255-0.270] | 0.093 [0.085-0.095] | 0.34 | dbcraft (2.9x) |
| idle, 0 players | CPU (cores) | 0.013 [0.013-0.014] | 0.013 [0.013-0.013] | 0.98 | TIE |
| idle, 0 players | memory PSS (MiB) | 1,009 [1,003-1,022] | 72.9 [65.3-117] | 0.07 | dbcraft (13.9x) |
| idle, 50 players | tick mean (ms) | 24.7 [23.6-25.1] | 3.11 [2.79-3.12] | 0.13 | dbcraft (8.0x) |
| idle, 50 players | tick p99 (ms) | 40.2 [38.2-44.5] | 7.56 [7.06-11.4] | 0.19 | dbcraft (5.3x) |
| idle, 50 players | CPU (cores) | 0.642 [0.604-0.643] | 0.094 [0.089-0.094] | 0.15 | dbcraft (6.8x) |
| idle, 50 players | chat p50 (ms) | 7.35 [2.26-13.6] | 5.08 [5.06-5.72] | 0.69 | TIE |
| idle, 50 players | chat p99 (ms) | 28.5 [28.0-29.0] | 16.3 [15.6-16.4] | 0.57 | dbcraft (1.7x) |
| idle, 50 players | memory PSS (MiB) | 1,431 [1,414-1,453] | 188 [186-191] | 0.13 | dbcraft (7.6x) |
| idle, 200 players | tick mean (ms) | 40.1 [39.4-41.4] | 5.91 [5.39-6.43] | 0.15 | dbcraft (6.8x) |
| idle, 200 players | tick p99 (ms) | 63.8 [58.8-69.1] | 12.7 [10.9-13.6] | 0.20 | dbcraft (5.0x) |
| idle, 200 players | CPU (cores) | 1.18 [1.14-1.21] | 0.209 [0.188-0.211] | 0.18 | dbcraft (5.7x) |
| idle, 200 players | chat p50 (ms) | 16.4 [4.28-29.2] | 6.82 [5.81-6.96] | 0.41 | TIE |
| idle, 200 players | chat p99 (ms) | 41.2 [32.1-50.1] | 27.5 [9.84-29.2] | 0.67 | dbcraft (1.5x) |
| idle, 200 players | memory PSS (MiB) | 1,488 [1,382-1,543] | 203 [200-204] | 0.14 | dbcraft (7.3x) |
| 50 players all walking | tick mean (ms) | 30.1 [28.7-30.7] | 15.8 [15.1-16.7] | 0.52 | dbcraft (1.9x) |
| 50 players all walking | tick p99 (ms) | 51.8 [47.0-56.4] | 28.8 [28.2-29.6] | 0.56 | dbcraft (1.8x) |
| 50 players all walking | CPU (cores) | 1.13 [1.11-1.17] | 0.382 [0.371-0.409] | 0.34 | dbcraft (3.0x) |
| 50 players all walking | chat p50 (ms) | 15.9 [2.54-29.3] | 7.46 [5.25-11.0] | 0.47 | TIE |
| 50 players all walking | chat p99 (ms) | 53.6 [46.0-71.3] | 27.4 [20.0-41.2] | 0.51 | dbcraft (2.0x) |
| 200 players all walking | tick mean (ms) | 45.8 [45.8-45.8] | 21.1 [21.1-21.1] | 0.46 | dbcraft (only 1 repetition: no range, treat as indicative) (2.2x) |
| 200 players all walking | tick p99 (ms) | 170 [170-170] | 33.5 [33.5-33.5] | 0.20 | dbcraft (only 1 repetition: no range, treat as indicative) (5.1x) |
| 200 players all walking | CPU (cores) | 1.84 [1.84-1.84] | 0.535 [0.535-0.535] | 0.29 | dbcraft (only 1 repetition: no range, treat as indicative) (3.4x) |
| 200 players all walking | chat p50 (ms; 10,000 = the probe's cap, no reply) | 5,019 [5,019-5,019] | 7.66 [7.66-7.66] | 0.00 | dbcraft (only 1 repetition: no range, treat as indicative) (654.9x) |
| 200 players all walking | chat p99 (ms) | 9,674 [9,674-9,674] | 34.6 [34.6-34.6] | 0.00 | dbcraft (only 1 repetition: no range, treat as indicative) (279.3x) |
| 200 players, 20% walking | tick mean (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 97.7 [96.6-98.1] | *39.9 [37.6-40.4]* | *0.41* | *dbcraft (2.4x)* |
| 200 players, 20% walking | tick p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 173 [170-174] | *93.4 [90.4-97.0]* | *0.54* | *dbcraft (1.9x)* |
| 200 players, 20% walking | CPU (cores) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 1.87 [1.80-1.91] | *0.955 [0.929-0.969]* | *0.51* | *dbcraft (2.0x)* |
| 200 players, 20% walking | chat p50 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 177 [55.9-362] | *81.2 [69.9-85.4]* | *0.46* | *TIE* |
| 200 players, 20% walking | chat p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 943 [407-1,189] | *153 [152-200]* | *0.16* | *dbcraft (6.2x)* |
| login storm: 50 joins in 1 s into 20 online | all joined, all chunks (s) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 44.4 [43.9-44.7] | *8.04 [7.78-8.29]* | *0.18* | *dbcraft (5.5x)* |
| login storm: 50 joins in 1 s into 20 online | worst tick (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 166 [121-171] | *165 [154-165]* | *1.00* | *TIE* |
| login storm: 50 joins in 1 s into 20 online | tick p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 89.7 [84.2-94.6] | *161 [152-164]* | *1.79* | *vanilla (1.8x)* |
| login storm: 50 joins in 1 s into 20 online | online players' chat p50 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 27.8 [26.6-31.0] | *146 [137-149]* | *5.26* | *vanilla (5.3x)* |
| login storm: 50 joins in 1 s into 20 online | online players' chat p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 252 [236-360] | *262 [230-275]* | *1.04* | *TIE* |
| login storm: 200 joins in 1 s into 20 online | all joined, all chunks (s) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 51.8 [51.6-53.1] | *39.9 [39.7-40.2]* | *0.77* | *dbcraft (1.3x)* |
| login storm: 200 joins in 1 s into 20 online | worst tick (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 545 [451-621] | *948 [908-958]* | *1.74* | *vanilla (1.7x)* |
| login storm: 200 joins in 1 s into 20 online | tick p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 120 [120-127] | *265 [241-273]* | *2.20* | *vanilla (2.2x)* |
| login storm: 200 joins in 1 s into 20 online | online players' chat p50 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 182 [142-188] | *216 [210-217]* | *1.18* | *vanilla (1.2x)* |
| login storm: 200 joins in 1 s into 20 online | online players' chat p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 2,408 [2,267-2,737] | *419 [398-1,119]* | *0.17* | *dbcraft (5.7x)* |
| one joiner, view distance 10 | unexplored world, all chunks (s) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 4.16 [3.99-4.22] | *0.687 [0.687-0.700]* | *0.17* | *dbcraft (6.1x)* |
| one joiner, view distance 10 | explored world, all chunks (s) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 1.55 [1.48-1.60] | *0.527 [0.525-0.550]* | *0.34* | *dbcraft (2.9x)* |
| edits, nobody in range | single block edit, statement (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 2.66 [2.45-2.92] | *3.90 [3.63-4.04]* | *1.46* | *vanilla (1.5x)* |
| edits, nobody in range | fill 1,000, statement (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 11.4 [11.0-13.0] | *5.90 [5.01-6.38]* | *0.52* | *dbcraft (1.9x)* |
| edits, nobody in range | fill 1,000, tick cost (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 10.1 [9.11-12.1] | *0.819 [0.000-2.85]* | *0.08* | *dbcraft (12.4x)* |
| edits, nobody in range | fill 100,000, statement (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 267 [266-325] | *71.1 [63.0-83.8]* | *0.27* | *dbcraft (3.8x)* |
| edits, nobody in range | fill 100,000, tick cost (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 245 [219-313] | *0.892 [0.000-1.10]* | *0.00* | *dbcraft (275.2x)* |
| edits, one viewer in range | single block edit, statement (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 2.78 [2.61-2.88] | *3.42 [2.93-3.57]* | *1.23* | *vanilla (1.2x)* |
| edits, one viewer in range | single block edit, tick cost (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 0.000 [0.000-0.113] | *17.2 [3.11-35.0]* | ** | *vanilla* |
| edits, one viewer in range | fill 1,000, statement (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 16.3 [11.1-17.6] | *5.38 [4.74-6.40]* | *0.33* | *dbcraft (3.0x)* |
| edits, one viewer in range | fill 1,000, tick cost (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 19.4 [12.8-27.8] | *79.9 [59.7-90.3]* | *4.13* | *vanilla (4.1x)* |
| edits, one viewer in range | fill 100,000, statement (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 344 [320-389] | *76.1 [72.4-79.9]* | *0.22* | *dbcraft (4.5x)* |
| edits, one viewer in range | fill 100,000, tick cost (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 352 [345-429] | *297 [290-391]* | *0.84* | *TIE* |
| admin edit path, nobody in range | single edits per second | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 995 [945-1,050] | *2,911 [2,738-3,004]* | *2.93* | *dbcraft (2.9x)* |
| 10,000-chunk flat world | generation (s) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 26.0 [25.8-27.1] | *2.08 [1.84-2.32]* | *0.08* | *dbcraft (12.5x)* |
| 10,000-chunk flat world | size after save (MiB) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 62.1 [62.1-62.1] | *14.9 [14.9-14.9]* | *0.24* | *dbcraft (4.2x)* |
| 10,000-chunk flat world | save stall (s) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 6.01 [5.64-7.84] | *0.068 [0.067-0.074]* | *0.01* | *dbcraft (88.4x)* |
| 10,000-chunk flat world | kill -9 to accepting logins (s) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 14.8 [14.8-15.8] | *2.27 [2.10-2.71]* | *0.15* | *dbcraft (6.5x)* |
| 10,000-chunk flat world | edit 1 s old, never saved, survives kill -9 (1 = yes) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 0.000 [0.000-0.000] | *1.00 [1.00-1.00]* | ** | *dbcraft* |
| terrain generation, 64 x 64 chunks (NOT like for like) | CPU per chunk (ms), not like for like | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 74.3 [72.1-77.5] | *8.24 [7.96-8.44]* | *0.11* | *dbcraft (9.0x)* |
| 10-minute soak, 200 walking players | CPU (cores) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 1.66 [1.65-1.66] | *1.00 [1.00-1.00]* | *0.61* | *dbcraft (only 2 repetitions: no range, treat as indicative) (1.7x)* |
| 10-minute soak, 200 walking players | clients dropped | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 0.000 [0.000-0.000] | *0.000 [0.000-0.000]* | ** | *TIE (only 2 repetitions: no range, treat as indicative)* |
| 10-minute soak, 200 walking players | chat p50 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 10,000 [10,000-10,000] | *202 [191-214]* | *0.02* | *dbcraft (only 2 repetitions: no range, treat as indicative) (49.4x)* |
| 10-minute soak, 200 walking players | tick mean (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* no usable samples | *108 [102-114]* | ** | *-* |
| 10-minute soak, 200 walking players | tick p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* no usable samples | *331 [294-367]* | ** | *-* |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | tick mean (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 135 [121-145] | *446 [301-750]* | *3.30* | *vanilla (3.3x)* |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | tick p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 2,126 [1,773-2,590] | *905 [490-1,042]* | *0.43* | *dbcraft (2.3x)* |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | clients dropped (of 500) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 0.000 [0.000-0.000] | *168 [103-240]* | ** | *vanilla* |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | clients in play when measured (of 500) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 500 [497-500] | *353 [285-407]* | *0.71* | *vanilla (1.4x)* |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | chat p50 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 10,000 [10,000-10,000] | *748 [470-970]* | *0.07* | *dbcraft (13.4x)* |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | server CPU (cores) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* 2.02 [1.99-2.09] | *1.01 [1.01-1.02]* | *0.50* | *dbcraft (2.0x)* |
| crowded spawn: 500 players in 30 x 30 chunks, all moving | load generator CPU (cores) | not run | not run | | |
| crowded spawn: 500 players in 30 x 30 chunks, 20% | tick mean (ms) | not run | not run | | |
| crowded spawn: 500 players in 30 x 30 chunks, 20% | tick p99 (ms) | not run | not run | | |
| crowded spawn: 500 players in 30 x 30 chunks, 20% | clients dropped (of 500) | not run | not run | | |
| crowded spawn: 500 players in 30 x 30 chunks, 20% | chat p50 (ms) | not run | not run | | |
| 500 players over 100 x 100 chunks, all moving | tick mean (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *279 [260-284]* | ** | *-* |
| 500 players over 100 x 100 chunks, all moving | tick p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *422 [417-455]* | ** | *-* |
| 500 players over 100 x 100 chunks, all moving | clients dropped (of 500) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *82.0 [70.0-141]* | ** | *-* |
| 500 players over 100 x 100 chunks, all moving | chat p50 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *430 [373-496]* | ** | *-* |
| 500 players over 100 x 100 chunks, all moving | server CPU (cores) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *1.01 [1.01-1.01]* | ** | *-* |
| 500 players over 100 x 100 chunks, all moving | load generator CPU (cores) | not run | not run | | |
| 500 players over 100 x 100 chunks, 20% moving | tick mean (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *58.3 [52.5-59.4]* | ** | *-* |
| 500 players over 100 x 100 chunks, 20% moving | tick p99 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *116 [104-124]* | ** | *-* |
| 500 players over 100 x 100 chunks, 20% moving | clients dropped (of 500) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *118 [82.0-132]* | ** | *-* |
| 500 players over 100 x 100 chunks, 20% moving | chat p50 (ms) | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* not run | *127 [111-143]* | ** | *-* |
| mobs: 500 awake cows, viewer in range | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* 16.0 [15.0-16.9] | *13.0 [12.0-14.1]* | *0.81* | *dbcraft (1.2x)* |
| mobs: 2,000 awake cows, viewer in range | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* 60.8 [57.4-63.3] | *33.2 [31.0-34.0]* | *0.55* | *dbcraft (1.8x)* |
| mobs: 5,000 awake cows, viewer in range | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* 149 [138-161] | *70.5 [69.3-78.2]* | *0.47* | *dbcraft (2.1x)* |
| mobs: 500 awake cows, nobody in range | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* 4.10 [4.05-4.45] | *15.5 [12.7-18.7]* | *3.78* | *vanilla (3.8x)* |
| mobs: 2,000 awake cows, nobody in range | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* 5.95 [5.85-6.15] | *33.9 [33.3-38.6]* | *5.69* | *vanilla (5.7x)* |
| mobs: 5,000 awake cows, nobody in range | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* 11.5 [10.3-11.7] | *76.1 [68.3-78.4]* | *6.62* | *vanilla (6.6x)* |
| mobs: 5,000 resting items, viewer in range | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* 72.2 [66.1-73.6] | *1.40 [1.33-2.21]* | *0.02* | *dbcraft (51.6x)* |

## What changed since the previous campaign (medians; before = campaign 1, after = this one; the ratio columns are host-neutral)

| Scenario | Metric | vanilla before -> after | dbcraft before -> after | ratio d/v before -> after | winner before -> after |
|---|---|---|---|---|---|
| idle, 0 players | tick mean (ms) | 0.350 -> 0.270 | 0.125 -> 0.093 | 0.36 -> 0.34 | dbcraft (2.8x) -> dbcraft (2.9x) |
| idle, 0 players | CPU (cores) | 0.018 -> 0.013 | 0.019 -> 0.013 | 1.01 -> 0.98 | TIE -> TIE |
| idle, 0 players | memory PSS (MiB) | 995 -> 1,009 | 118 -> 72.9 | 0.12 -> 0.07 | dbcraft (8.4x) -> dbcraft (13.9x) |
| idle, 50 players | tick mean (ms) | 44.0 -> 24.7 | 15.4 -> 3.11 | 0.35 -> 0.13 | dbcraft (2.9x) -> dbcraft (8.0x) |
| idle, 50 players | tick p99 (ms) | 77.0 -> 40.2 | 67.8 -> 7.56 | 0.88 -> 0.19 | TIE -> dbcraft (5.3x) |
| idle, 50 players | CPU (cores) | 1.10 -> 0.642 | 0.355 -> 0.094 | 0.32 -> 0.15 | dbcraft (3.1x) -> dbcraft (6.8x) |
| idle, 50 players | chat p50 (ms) | 31.2 -> 7.35 | 57.6 -> 5.08 | 1.84 -> 0.69 | vanilla (1.8x) -> TIE |
| idle, 50 players | chat p99 (ms) | 60.4 -> 28.5 | 88.9 -> 16.3 | 1.47 -> 0.57 | vanilla (1.5x) -> dbcraft (1.7x) |
| idle, 50 players | memory PSS (MiB) | 1,430 -> 1,431 | 209 -> 188 | 0.15 -> 0.13 | dbcraft (6.8x) -> dbcraft (7.6x) |
| idle, 200 players | tick mean (ms) | 69.0 -> 40.1 | 20.6 -> 5.91 | 0.30 -> 0.15 | dbcraft (3.4x) -> dbcraft (6.8x) |
| idle, 200 players | tick p99 (ms) | 119 -> 63.8 | 72.8 -> 12.7 | 0.61 -> 0.20 | dbcraft (1.6x) -> dbcraft (5.0x) |
| idle, 200 players | CPU (cores) | 1.47 -> 1.18 | 0.558 -> 0.209 | 0.38 -> 0.18 | dbcraft (2.6x) -> dbcraft (5.7x) |
| idle, 200 players | chat p50 (ms) | 43.2 -> 16.4 | 14.9 -> 6.82 | 0.34 -> 0.41 | dbcraft (2.9x) -> TIE |
| idle, 200 players | chat p99 (ms) | 89.4 -> 41.2 | 69.6 -> 27.5 | 0.78 -> 0.67 | TIE -> dbcraft (1.5x) |
| idle, 200 players | memory PSS (MiB) | 1,672 -> 1,488 | 215 -> 203 | 0.13 -> 0.14 | dbcraft (7.8x) -> dbcraft (7.3x) |
| 50 players all walking | tick mean (ms) | 61.6 -> 30.1 | 51.3 -> 15.8 | 0.83 -> 0.52 | dbcraft (1.2x) -> dbcraft (1.9x) |
| 50 players all walking | tick p99 (ms) | 102 -> 51.8 | 110 -> 28.8 | 1.07 -> 0.56 | TIE -> dbcraft (1.8x) |
| 50 players all walking | CPU (cores) | 1.53 -> 1.13 | 0.986 -> 0.382 | 0.64 -> 0.34 | dbcraft (1.6x) -> dbcraft (3.0x) |
| 50 players all walking | chat p50 (ms) | 51.1 -> 15.9 | 88.5 -> 7.46 | 1.73 -> 0.47 | vanilla (1.7x) -> TIE |
| 50 players all walking | chat p99 (ms) | 121 -> 53.6 | 208 -> 27.4 | 1.71 -> 0.51 | vanilla (1.7x) -> dbcraft (2.0x) |
| 200 players all walking | tick mean (ms) | 81.5 -> 45.8 | 98.7 -> 21.1 | 1.21 -> 0.46 | vanilla (1.2x) -> dbcraft (only 1 repetition: no range, treat as indicative) (2.2x) |
| 200 players all walking | tick p99 (ms) | 799 -> 170 | 225 -> 33.5 | 0.28 -> 0.20 | dbcraft (3.6x) -> dbcraft (only 1 repetition: no range, treat as indicative) (5.1x) |
| 200 players all walking | CPU (cores) | 1.89 -> 1.84 | 1.01 -> 0.535 | 0.54 -> 0.29 | dbcraft (1.9x) -> dbcraft (only 1 repetition: no range, treat as indicative) (3.4x) |
| 200 players all walking | chat p50 (ms; 10,000 = the probe's cap, no reply) | 10,000 -> 5,019 | 185 -> 7.66 | 0.02 -> 0.00 | dbcraft (54.2x) -> dbcraft (only 1 repetition: no range, treat as indicative) (654.9x) |
| 200 players all walking | chat p99 (ms) | 10,000 -> 9,674 | 307 -> 34.6 | 0.03 -> 0.00 | dbcraft (32.6x) -> dbcraft (only 1 repetition: no range, treat as indicative) (279.3x) |

## Ranked remaining losses (from the cells that were re-run, plus the known open ones, which were NOT re-measured here)

Of the cells re-run on the final tree (idle 0 / 50 / 200 players, 50 and 200 walking players) **dbcraft loses no row any more**: every one is a win or a TIE (campaign 1's losses at 50 players, the chat p50 / p99 of idle and of walking players, are now ties or wins).  What is still a loss is in rows that this campaign could not re-run; their numbers below are from
campaign 1 (tree `f205b34`, other VM) or from the capacity track's own document, and are labelled so:

1. **500 players, crowded (30 x 30 chunks).**  Not re-run.  Campaign 1: dbcraft tick 446 [301-750] ms against vanilla's 135 [121-145] ms, 103-240 of 500 clients dropped.  `docs/PERF-CAPACITY.md` (capacity track, shared machine, not this campaign): 778 / 884 ms with 0 dropped.  Still a large loss.
2. **500 players, sparse (100 x 100 chunks), all moving.**  Not re-run, and **vanilla was never measured at 500 sparse** (planned, not run).  Campaign 1: 279 ms with 70-141 dropped; PERF-CAPACITY: 131-143 ms wall on a quiet machine, 0 dropped, short of its 100 ms target.  The 20%-moving case (58 ms in campaign 1) was not re-run.
3. **The locator-bar cliff at 50-120 players.**  `docs/PERF-CAPACITY.md`: the locator bar (`mc.vis_wp_pass`, every pair of players every tick) was half of a walking tick at 50-120 players, and is **switched off above 120 players** (`dbcraft.locator-bar-max-players`).  Consequence for this document: **the 200-walker row runs with the bar off** and is therefore cheaper per player than the 50-walker row; a 100-walker cell was not run.
4. **A viewer with mobs just outside his view.**  Not re-run.  `docs/PERF-MOBS2.md` (own session): 1.25x vanilla at 2,000 and 5,000 cows (the lane ends each time a mob crosses the edge of his view).  Campaign 1 had this case at 3.8-6.6x worse than vanilla before the lazy lanes; the whole mobs block was not re-run, and `dbcraft.entity-mode` is `off` as shipped.
5. **Login storms and edits with a viewer.**  Not re-run.  Campaign 1: 200 joins worst tick 948 against 545 ms, tick p99 265 against 120 ms; 1,000-block fill tick cost with a viewer 80 against 19 ms.  The storm round 2 and dynamics fixes aim at exactly these; not measured here.

## What is NOT comparable (short; the full list is in `SCOREBOARD-2026-11-04-campaign1.md`, still valid)

* dbcraft is a flat-world server with no light engine, no mob AI or pathfinding (mobs off by default), no redstone, no leaf decay or shape updates, no item drops from broken blocks, about 70 of vanilla's 90 commands unimplemented, advancements and recipes replayed from a capture, offline mode for real clients only.
  Several wins (memory, CPU, join time, idle tick) come from not doing that work.  It does run the survival core, vanilla's player tracker, containers, fluids / falling blocks / random ticks.
* The 200-walker row has the locator bar off (above); 200 is one repetition only (the campaign was cut short), so no TIE rule applies to it; vanilla's chat p50 there is the probe cap or 5 s, i.e. its main thread was saturated.
* **Different VM from campaign 1** (faster host): compare ratios, not milliseconds, across the two campaigns.  The load generator shares the cores.  `fsync=off`: crash rows are process kills.  Chat percentiles rest on about 60 round trips per run.

## What was not re-run on the final tree, and why

The task was cut short by a decision to stop the 7-hour campaign after the container had been restarted three times (every restart lost the `/dev/shm` cluster and the cell in progress; completed cells survived because raw results are committed during the run).  **Completed on the final tree:**
idle 0 / 50 / 200 players (3 repetitions), 50 walking players (3), 200 walking players (1).  **Not re-run, shown in italics with campaign 1's values:** 200 walking at 20%, login storms (50 / 200 joins), one joiner, single edits and fills (nobody / one viewer), the admin edit path, the 10,000-chunk world (generation, size, save stall, kill -9), terrain generation,
the mobs rows (including the `reset=1` and nobody-connected cells), every 500-player cell on both servers (vanilla sparse 500 and crowded 500 at 20% and 100%), the 10-minute soak and the dynamics-off diagnosis.  The harness for all of them is in `tools/scoreboard/` (`resume.sh` runs the missing cells and skips the finished ones).

## Reproduce

```
tools/scoreboard/resume.sh                      # starts or resumes the whole campaign (cluster in /dev/shm/sb, results in docs/final-campaign/, a commit per minute while cells finish)
python3 tools/scoreboard/make_final_docs.py     # rewrites docs/SCOREBOARD.md tables, SCOREBOARD-table.md and the raw copies from the results on disk
```
