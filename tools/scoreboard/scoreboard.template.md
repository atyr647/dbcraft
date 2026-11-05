# Scoreboard: dbcraft against the real vanilla 26.3 server (final campaign)

Second campaign, run on the FINAL tree (main at `400f628`: dynamics fixes, storm round 2, mobs phase 2, idle track 2, the capacity track), against the real vanilla 26.3 jar (SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`).  It replaces the first campaign (`SCOREBOARD-2026-11-04-campaign1.md`, tree `f205b34`), whose files are kept with that date suffix.

{{STATE}}

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

{{HEADLINE}}

## What changed since the previous campaign (medians; before = campaign 1, after = this one; the ratio columns are host-neutral)

{{CHANGED}}

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
