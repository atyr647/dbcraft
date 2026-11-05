# Scoreboard: dbcraft against the real vanilla 26.3 server (final campaign)

Second campaign, run on the FINAL tree (main at `400f628`: dynamics fixes, storm round 2, mobs phase 2, idle track 2, the capacity track), against the real vanilla 26.3 jar (SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`).  It replaces the first campaign (`SCOREBOARD-2026-11-04-campaign1.md`, tree `f205b34`), whose files are kept with that date suffix.

{{STATE}}

**The virtual machine is not the one of campaign 1.**  The container was restarted several times during this campaign and came back on a faster host: vanilla's own idle-50 tick fell from 44 to
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

## Diagnosis: what the dynamics cost (dbcraft with `dbcraft.dynamics = off`, not a supported configuration)

{{DIAG}}

## Reproduce

```
tools/scoreboard/resume.sh                      # starts or resumes the whole campaign (cluster in /dev/shm/sb, results in docs/final-campaign/, a commit per minute while cells finish)
python3 tools/scoreboard/make_final_docs.py     # rewrites docs/SCOREBOARD.md tables, SCOREBOARD-table.md and the raw copies from the results on disk
```
