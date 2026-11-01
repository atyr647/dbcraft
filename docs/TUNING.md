# Tuning PostgreSQL for dbcraft

What the server's PostgreSQL and storage settings should be, with the measurements behind each choice, the root causes found for the slow ticks, and what is still open.
Nothing here changes game logic: every recommendation is a configuration setting, a storage parameter, an opt-in prototype, or a finding for the owner of some SQL.

## Read this first

* **Recommended server settings:** [`docker/postgresql.conf`](../docker/postgresql.conf).  **Settings that live in the database:** [`sql/450_tuning.sql`](../sql/450_tuning.sql) (database defaults, log retention),
  [`sql/455_storage_params.sql`](../sql/455_storage_params.sql) (column statistics), opt-in [`sql/456_player_live.sql`](../sql/456_player_live.sql) (state tiering).
* **Server configuration is a small lever for this workload.**  Of about twenty settings compared (2-3 interleaved runs each) only four moved the tick by more than the noise, and one is dev-only:
  `jit` on (+8 ms, **bad**), a large `shared_buffers` (+3 ms, **bad**, for a reason that is a design cost, below), `autovacuum_naptime` at the 1-minute default (**queue tables 10x bigger, +4 ms**), and `fsync` off (-6 ms, **dev only**).
* **The large costs are in how the tick uses the database, not in PostgreSQL's settings.**  Findings for the owners of that SQL, each with its evidence, in "Root causes": stale statistics that once cost a
  **4-second tick**; **10 ms of every tick** spent making commits cheap to read but expensive to write (temp-table and queue truncation); a chunk-cache hit that costs **430 us** and writes WAL; and autovacuum that **cannot see**
  a gateway that runs as one long `CALL`.
* **Two operational hazards matter more than any setting:**
  1. **The PL/Python development gateway blinds autovacuum** (its queue tables grew to 65 MB in 100 s, ticks 4 ms slower).  Fixed by [`tools/janitor.sh`](../tools/janitor.sh), which the container starts next to it.
     An external gateway that sends one statement per tick does not have the problem.
  2. **One forgotten idle-in-transaction session** (a psql window): the average tick was **3x slower within 30 s and 10x within a minute**, and recovered within seconds of the session ending.  Guard: `idle_in_transaction_session_timeout = 10s`.
* **WAL per tick (37 KB at 200 bots, 25% moving) is made of:** player-state updates 31%, row locks on the chunk table 16% (mostly full-page images), autoanalyze of payload columns 16%, catalog churn from temp tables and truncation about 30%
  (commit records and standby locks included).  What cuts each is in "WAL per tick".
* **State tiering** (the coordinator's question, [section below](#state-tiering-for-per-player-live-state)): an UNLOGGED live table cuts the player state's WAL by 99% (119 -> 1.1 KB per tick at 500 players all moving) and costs
  "after a crash players return up to N seconds back".  It does not make the tick faster on this machine.  A narrower LOGGED table buys nothing.

## How it was measured

Everything is reproducible from `tests/bench/tuning/` (scripts, configuration sets, the raw matrix summaries; per-trial CSVs and logs are not kept in git).

| Piece | What it does |
|---|---|
| `prepare.sh` | builds the **golden data directory**: the e2e database (`tests/e2e/setup.sh`) plus a warm flat world over the 100 x 100 chunk area the bots walk in (14,884 chunks generated and cached, 153 MB), vacuumed and frozen |
| `run.sh NAME CONFS ...` | one **trial**: copies the golden directory (every trial starts from identical bytes), starts a fresh cluster with `conf/base.conf` (logging only) plus the named `conf/*.conf` files, sets up N bots (`tests/bench/integration/bench.sql`), analyses the database, warms up, snapshots the server's counters, runs the measured window at 20 Hz, snapshots again, analyses.  Options: `APPLY=` (SQL files), `STALL=1` / `STALL_GUARD=`, `JANITOR=`, `DIAG=1`, `WALSTAT=1`, `MODE=` |
| `steady.sql`, `steady_top.py` | the load: the synthetic gateway of `tests/bench/integration` (input frames in, `mc.server_tick()`, output drained) plus **keep-alive and teleport answers like a real client** (without them the server kicks every bot after 30 s: a mass-kick storm that looked like an 18-second tick in my first run).  **`MODE=proc`** runs the loop inside one `CALL` with a COMMIT per tick (the shape of the PL/Python development gateway); **`MODE=top`** sends every step as a top-level statement of one psql session (the shape of an external gateway).  The difference matters, see "Autovacuum is blind" |
| `analyze.py` | per-tick latency (what the gateway waits for: tick + drain + commit), counter differences (WAL, checkpoints, buffers, per-table updates / HOT / dead tuples / vacuums / sizes, index scans), and **which server events overlap each slow tick** (from the server log) |
| `matrix.sh`, `table.py`, `qsize.py` | run configurations **interleaved** over repetitions (round 1 of all, then round 2 ...), report **medians** and the spread of the per-run averages as the noise |
| `walstat.py`, `live_state.sh`, `truncate_cost.sh`, `chunkpath.sh`, `drain_mem.sh`, `xmin_probe.sh`, `walgen.sh`, `jitter.sql`, `afterevents.py`, `timeline.py` | single-question experiments used below |

Scenario for the matrices: **200 bots, 25% moving each tick, view distance 10, warm world, 75-180 s windows, 2-3 repetitions per configuration.**  200 bots because at 300 moving bots the tick itself exceeds 50 ms on this machine and every tick is late, which
hides the outliers.  The machine: 4 cores, ext4 on a virtual disk, **shared with other workers throughout (load average 1 to 5)**: wall-clock numbers carry 5-25% noise (the `spread` column says how much), counters (WAL, buffers, vacuums) do not.
All numbers are for the code revision at commit `d34f51f`; the tick's SQL is being optimised concurrently by other workers, so absolute milliseconds will move, relative findings should not.

## Root causes of slow ticks

At this load: median tick 41-49 ms, p99 75-90 ms, p99.9 190-350 ms, worst 350-600 ms, about 1-2% of ticks over twice the median; in the first runs also single ticks of 4 s.

**What was ruled out.**  Of 2,042 slow ticks in the first matrix, 10 overlapped an autovacuum run, 8 an autoanalyze, 1 a lock wait, and none a checkpoint (99.5% overlapped nothing; `attribution.py s1`; 96% in matrix s3, which runs autovacuum far more often).  Ticks that **start within a second after** an autovacuum/autoanalyze run ended are not slower either (1.2-1.7% slow against 1.2% for all other ticks, `afterevents.py`): **plan invalidation after ANALYZE is not a measurable cause**.  Checkpoints
(forced every minute: 3 per 180 s run) did not change the tick (45.5 ms against 45.4 ms, matrix s5).  And it is not the machine: a backend spinning on `clock_timestamp()` for 40 s at load 4.4 never paused longer than 18.7 ms (`jitter.sql`).
The slow ticks are **statements**.

| # | Cause | Evidence | Who can fix it |
|---|---|---|---|
| 1 | **Stale statistics flip a plan.**  The step that copies keep-alive answers into the game queue (`insert into mc.play_in ... from net.batch b join net.conn c ... where net.pid(b.payload) = any(array[mc.sid('keep_alive'), mc.sid('accept_teleportation')])`) was planned as a nested loop over `net.batch` per connection (the planner believed `net.conn` had 1 row), and `mc.sid()` is a `STABLE` SQL function with a sub-select, which is **not inlined**, so it ran once per row: 89,700 evaluations, 541,000 buffer hits, **3.9 s** (auto_explain).  First at the first keep-alive tick (tick 301), then every 300 ticks, until statistics were refreshed.  `ANALYZE` of the whole database after the bulk load removed it (max tick 4.1 s -> 0.54 s) | auto_explain plan; before/after in the calibration runs | **configuration**: fresh statistics (section "Autovacuum is blind": the same cause); **code**: make the `mc.sid`/`net.pid` lookups constants (`IMMUTABLE`, or evaluated once into a variable) so the plan is safe whatever the statistics say |
| 2 | **Commit cost: every tick commits about 6.5 ms, whatever `synchronous_commit` is.**  Two parts, measured in isolation (`truncate_cost.sh`): ten `ON COMMIT DELETE ROWS` temp tables with a primary key cost **3.7-4.8 ms** per commit (truncating a temp table rewrites catalog rows), and eight `TRUNCATE`s of UNLOGGED queue tables cost **1.4 ms** (0.77 ms with fsync off: each truncate of an unlogged table creates an init fork and fsyncs it).  The same eight consumed with `DELETE` cost **0.08 ms** | `truncate_cost.sh`; `commit_avg` of every in-procedure trial | **code**: temp tables `ON COMMIT PRESERVE ROWS` with explicit deletes (or none); queues consumed without TRUNCATE |
| 3 | **Truncation makes `shared_buffers` expensive**: dropping the old file of a truncated table scans the whole buffer pool at commit.  Eight truncates + commit: **1.4 ms at 128 MB, 1.5 ms at 32 MB, 9.4 ms at 2 GB**; in the full tick the commit goes 6.5 ms (128 MB) -> 7.2 (512 MB) -> 10.7 (2 GB) | `truncate_cost.sh`; matrix s1 | **configuration**: keep `shared_buffers` small (done); **code**: remove the truncates and the buffer size stops mattering |
| 4 | **A chunk-cache hit costs about 430 us**, not 15-23 us.  `mc.chunk_packet` calls `ensure_chunk_current`, which does `SELECT ... FOR UPDATE` on the chunk row on every call, even a cache **hit**: a row lock is a write (page dirtied, a `Heap LOCK` WAL record: **16% of all the WAL** in a steady-state window, 7.8 MB of it full-page images after the checkpoint), then three more lookups in PL/pgSQL.  A lock-free pre-check cut the WAL by 16% (31 against 37 KB per tick) and the fetch by 0-18% (two runs); most of the rest is the per-call overhead of the function chain.  441 chunks (one join) = 190 ms to fetch | `chunkpath.sh`; `wal1/walstat.txt`; matrix s4 `top_lockfree` | **code** (world module) |
| 5 | **A gateway that runs as one long `CALL` hides its churn from autovacuum** (below): queue tables of 65 MB after 100 s instead of 5 MB; ticks 4 ms slower and twice as many over 50 ms | matrix s3 | **configuration**: `tools/janitor.sh`, or an external gateway |
| 6 | **A session idle inside a transaction**: tick 3x slower within 30 s (below) | matrix s4 | **configuration**: `idle_in_transaction_session_timeout` |
| 7 | **Keep-alive answer ticks**: every 300 ticks all bots answer, 450 inbound frames instead of 250, and the *process* phase takes +100 to +167 ms (ticks 201, 501, 801, 1101 ...), in gateway mode too, with fresh statistics.  Suspect: the per-row `mc.sid()` of cause 1 (if it is the per-row calls, about 0.25 ms each) | `ms_process` of the slowest ticks of every trial | **code** (net/game) |
| 8 | **Stalls of 100-300 ms in statements that do almost nothing**: `mc.broadcast_block_events()` took 217 ms with 140 buffer hits and 1 page written (auto_explain), the block phase spikes 56-290 ms although the benchmark has no block events.  The function truncates two unlogged tables; I/O on the shared disk is the suspect (not CPU: see jitter; not autovacuum/checkpoint). <<S7-TMPFS>> | `diag2`, `slowlog.py` | the truncates (code); fast storage |
| 9 | **Join and chunk-streaming bursts**: `ms_chunks` spikes of 250-390 ms when many chunks are needed in one tick; `net.drain_outbox` spills to temp files when the queued bytes exceed `work_mem` (20 simultaneous joiners queue 60 MB: 30 MB temp file with 4 MB and 16 MB, none with 64 MB) | `drain_mem.sh` | `work_mem = 64MB` (config); chunk generation off the tick (code, other worker) |
| 10 | **Not a cause, a harness bug of mine**: bots that never answer keep-alive are kicked all at once after 30 s: 92,604 output frames in one tick, an 18 s tick.  Fixed in `tune.gen` | first calibration | - |

## Autovacuum is blind to a long `CALL`

PostgreSQL's autovacuum decides from the table statistics that backends **report**, and a backend reports them when it goes **idle** (between top-level statements).  A procedure that COMMITs every tick but never returns (the PL/Python development gateway
`call net.run(...)`, and my `MODE=proc` loop) is never idle inside its `CALL`, so autovacuum and autoanalyze see none of its inserts and deletes.  Measured with `xmin_probe.sh`: the backend's xmin age is 1-4 (it does **not** pin the horizon) and vacuum
removes what it is shown, but `pg_stat_user_tables` shows 0 dead tuples for `mc.play_out` while the file grows 1.5 MB every 5 s.  Consequences: queue tables that grow without bound (every queue consumed with `DELETE`: `net.inbox`, `net.outbox`, `mc.play_in`,
`mc.play_out`), and statistics that go stale (cause 1).  The queues consumed with `TRUNCATE` stay at 56 KB.

Matrix s3 (in-procedure loop, 100 s, 3 runs, medians) and s4 (gateway style, same load):

| matrix | mode and configuration | queue tables at the end (4 tables together) | dead tuples at the end | autovacuum runs on them | avg tick | p99 | ticks over 50 ms |
|---|---|---|---|---|---|---|---|
| s3 | in-procedure, defaults (`proc_ref`) | **64.6 MB** | 1,833,831 | 7 | 48.6 ms | 84.5 | 730 |
| s3 | in-procedure + `tools/janitor.sh` every 5 s (`proc_janitor`) | **5.2 MB** | 1,848,410 (never reported, never needed) | - | **44.5 ms** | 75.3 | **353** |
| s3 | gateway style, `autovacuum_naptime = 10s` (`top_av`) | 6.0 MB | 4,106 | 40 | 49.1 ms | 85.7 | 618 |
| s3 | gateway style, 10 s + per-table queue thresholds (`top_qav`, `apply/q_av.sql`) | 6.9 MB | 20,193 | 44 | 47.4 ms | 86.1 | 659 |
| s4 | gateway style, default `autovacuum_naptime = 1min` (`top_ref`) | **53.0 MB** | 208,803 | 8 | 48.2 ms | 87.6 | 663 |
| s4 | gateway style, `autovacuum_naptime = 10s` (`top_av`) | **5.5 MB** | 3,677 | 40 | 43.8 ms | 87.8 | 418 |

(Averages are only comparable within a matrix: the machine's load differed between s3 and s4.)

* **Gateway style needs a short `autovacuum_naptime` (10 s), nothing else**: 10x smaller queues and 4 ms faster ticks than the 1-minute default.  Per-table thresholds on the queues add nothing (the default threshold is already tiny: they are re-vacuumed
  at every pass), so `sql/455` does not set them.
* **In-procedure needs the janitor**: `tools/janitor.sh [seconds]` runs `VACUUM (ANALYZE, SKIP_LOCKED)` of the hot tables from a session of its own (the container's entrypoint starts it next to the gateway).  Cost: the vacuum of eleven tiny tables, a few
  milliseconds every 5 s.  An `autovacuum_naptime` of 5 s with no cost delay **does not** help here (`av_fast`: 54.1 ms against 50.8; the vacuum has nothing to see).
* **Trade-off of a short naptime:** every queue table is also re-ANALYZEd each pass, which rewrites its statistics rows: 16% of the WAL (see "WAL per tick" and `sql/455`).
* A better fix is in the tick: consume a queue that is read whole with `TRUNCATE` (no dead tuples at all), or avoid long `CALL`s in the gateway.

## The idle-in-transaction stall

One session that took a snapshot and went idle inside its transaction (repeatable read, as an interactive psql window with an open `BEGIN` does) pins the vacuum horizon for **every table in the database**: dead queue and player tuples cannot be removed, tables
and indexes grow, every scan and every HOT update gets slower.  Matrix s4 (gateway style, naptime 10 s, 100 s, 3 runs; the stalled runs took 210 s because the ticks were so slow):

| configuration | avg tick | p99 | ticks over 100 ms | dead tuples | autovacuum runs (cannot reclaim) |
|---|---|---|---|---|---|
| no stall (`top_av`) | **43.8 ms** | 87.8 | 12 | 3,677 | 68 |
| **idle session, no guard** (`top_stall`) | **137.0 ms** | **739.2** | **552** | 68,883 | 212 |
| idle session, guard 3 s (`top_stallguard`) | 45.5 ms | 104.9 | 22 | 47,865 | 71 |
| idle session, guard 10 s (`guard10`, 1 run) | 49.6 ms | 113.5 | 27 | | 70 |

How it develops (average tick per 10 s of the first stalled run): 87, 124, 206, 245, 267, 303, 405, 451 ms ... **692 ms at 170 s**; and the moment the session ends (at 210 s) the next bucket is 85 ms, then 52, 49: recovery is immediate.  So a long guard
is expensive: the damage is already 2x at 10 s and 10x at a minute.  `idle_in_transaction_session_timeout = 10s` (in `docker/postgresql.conf` and `sql/450_tuning.sql`) ends the offender after 10 s; an admin who needs longer sets it to 0 for their own session.
`statement_timeout` cannot be set database-wide: the development gateway is one statement that runs for days (set it per role, not for the gateway's).  `lock_timeout` was not evaluated.

## Settings compared

**Matrix s1** (in-procedure loop, 75 s, 3 interleaved runs, medians).  Reference = durable (`fsync = on`), `synchronous_commit = off`, `jit = off`, `max_connections = 200`; each row changes one thing.  `spread` is max minus min of the three per-run averages:
differences smaller than it are noise.

| config | avg ms | p50 | p99 | p99.9 | max | ticks > 50 ms | ticks > 100 ms | commit avg ms | WAL KB/tick | spread | verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **ref** | 50.8 | 49.2 | 87.0 | 316 | 490 | 702 | 11 | 6.50 | 37 | 2.4 | the baseline |
| stock (PostgreSQL defaults: sync commit on, jit on, ...) | 56.2 | 53.5 | 118.7 | 273 | 363 | 855 | 35 | 6.08 | 37 | 6.8 | worse: mostly `jit` |
| dev (what `tools/pg-dev.sh` starts: fsync off, sync off, jit on) | 49.9 | 47.4 | 103.4 | 229 | 320 | 652 | 19 | 6.14 | 37 | 4.7 | |
| `synchronous_commit = on` | 49.5 | 46.2 | 86.9 | 285 | 425 | 545 | 10 | 6.14 | 37 | 2.1 | **no measurable cost here** (fast local flush); see the risk table |
| `fsync = off` | 44.4 | 40.2 | 81.6 | 273 | 438 | 305 | 10 | 6.43 | 37 | 4.2 | -6 ms, **DEV ONLY**: a crash can corrupt the cluster |
| `wal_level = minimal` | 50.3 | 47.1 | 106.8 | 319 | 421 | 606 | 16 | 6.20 | 33 | 2.4 | no gain; forbids base backups and replication |
| `wal_compression = on` (pglz) | 54.2 | 46.5 | 146.6 | 378 | 466 | 574 | 45 | 7.33 | 31 | 5.2 | tail worse in this run: see lz4 below |
| `full_page_writes = off` | 49.5 | 45.1 | 90.4 | 273 | 372 | 518 | 14 | 6.21 | 31 | 5.2 | -16% WAL, no time; torn-page risk |
| `shared_buffers = 512MB` | 53.4 | 48.1 | 103.6 | 348 | 415 | 698 | 19 | 7.23 | 37 | 11.6 | worse commit (cause 3) |
| `shared_buffers = 2GB` | 53.9 | 50.3 | 97.6 | 208 | 389 | 772 | 13 | 10.73 | 37 | 16.3 | **worse commit: 10.7 ms** |
| `work_mem = 64MB` | 48.0 | 45.5 | 86.0 | 319 | 449 | 498 | 12 | 5.91 | 36 | 1.2 | within noise at this load (no spill); needed for join storms |
| `max_parallel_workers_per_gather = 0` | 50.3 | 47.7 | 89.6 | 272 | 458 | 626 | 10 | 6.18 | 37 | 5.4 | no change (nothing in the tick goes parallel) |
| `jit = on` | 58.6 | 54.7 | 117.2 | 363 | 484 | 901 | 33 | 6.34 | 37 | 2.9 | **worse: +8 ms, ticks over 100 ms x3** |
| `plan_cache_mode = force_custom_plan` | 58.5 | 53.1 | 180.0 | 271 | 361 | 893 | 28 | 7.02 | 37 | 22.2 | **worse** (replanning every statement) |
| `random_page_cost = 1.1`, `effective_cache_size = 8GB` | 48.3 | 46.2 | 83.7 | 256 | 378 | 528 | 12 | 6.18 | 36 | 4.7 | within noise; harmless planner hints |
| `autovacuum_naptime = 5s`, no cost delay | 54.1 | 52.3 | 102.0 | 266 | 421 | 833 | 17 | 6.25 | 37 | 6.6 | worse in the in-procedure loop (nothing to see for vacuum) |
| `wal_writer_delay = 50ms` | 51.8 | 48.3 | 92.6 | 273 | 595 | 669 | 14 | 6.33 | 37 | 7.2 | no change |

**Matrix s5 - checkpoints** (gateway style, 180 s windows, 2 runs; medians; `ckpt_1min` = `checkpoint_timeout = 1min`, 3 checkpoints per run, `ckpt_1min_bgw` adds `bgwriter_delay = 20ms`, `bgwriter_lru_maxpages = 400`, `bgwriter_lru_multiplier = 4`):

| config | avg ms | p50 | p99 | p99.9 | max | ticks > 100 ms | WAL KB/tick | spread |
|---|---|---|---|---|---|---|---|---|
| `ck_default` (timeout 5 min: no checkpoint inside the window) | 45.4 | 41.9 | 114.3 | 271 | 580 | 84 | 35 | 2.0 |
| `ck_1min` | 45.5 | 43.1 | 82.2 | 196 | 369 | 24 | 40 | 2.3 |
| `ck_1min_bgw` | 46.2 | 43.6 | 87.2 | 241 | 392 | 25 | 40 | 3.9 |

Checkpoints do not hurt the tick: spread-out checkpoints (`completion_target = 0.9`) write a few hundred pages.  The only cost is **WAL volume** (+14%: every page touched after a checkpoint is logged in full again, 3% of records are full-page images).  The bgwriter settings
change nothing.  Hence the recommendation of a **long** `checkpoint_timeout` (15 min) with a large `max_wal_size`.  (A timed checkpoint inside the default run did not happen, so the slow ticks of `ck_default` are not checkpoints; they are the same statement stalls as cause 8.)

**Matrix s6 - statistics tracking** (gateway style, 75 s, 3 runs):

| config | avg ms | p99 | ticks > 50 ms | spread |
|---|---|---|---|---|
| base | 42.6 | 76.9 | 234 | 1.6 |
| `track_activities = off` | 43.5 | 72.0 | 252 | 5.6 |
| **`track_io_timing = on`** | **45.2** | 78.5 | **343** | 4.0 |

`track_io_timing` costs about 2.6 ms per tick (a clock read around every buffer read and write; the tick does about 188,000 backend buffer writes in 75 s): **leave it off**, turn it on for a diagnosis only.  `track_activities = off` gains nothing.

<<S7-MATRIX>>

Temp files were 0 in every trial at 200 bots.  `commit_delay` was not evaluated (it only helps when many sessions commit at the same moment; the gateway commits once per statement).  `huge_pages` could not be evaluated: the host had no huge pages reserved (`HugePages_Total: 0`);
`huge_pages = try` is set and costs nothing.

## WAL per tick: what it is made of

`pg_waldump` over a 1,500-tick window (`wal1`, gateway style, 200 bots, 25% moving, naptime 10 s): **55.7 MB = 37.1 KB per tick (0.74 MB/s, 2.7 GB/hour)**.

| source | KB per tick | share | what cuts it |
|---|---|---|---|
| `mc.player` updates (`Heap HOT_UPDATE`, 179,355 records) | 11.6 | 31% | **state tiering** (an UNLOGGED live table: -99% of this, below); nothing narrower helps |
| `mc.chunk` row locks (`Heap LOCK`, 22,429 records, 7.8 of 8.9 MB are full-page images) | 5.9 | 16% | lock-free pre-check in `ensure_chunk_current` (code; measured -16% of all WAL); `wal_compression` shrinks the full-page images |
| `pg_statistic` (autoanalyze of the queues: every 10 s each of 8 queue tables rewrites most-common-value lists and histograms of 1 KB `bytea` values) | 5.8 | 16% | `alter column ... set statistics 0` on the payload columns (**`sql/455`**) |
| catalog churn: `pg_class` and its indexes (the ten temp tables and the unlogged truncates rewrite catalog rows at every commit), `Storage CREATE`: 25,500 records | about 8 | 22% | the tick's temp tables / truncates (code) |
| commit records (3 transactions per tick, each lists the relation files to drop) | 2.2 | 6% | same |
| `Standby LOCK` (the AccessExclusive locks of every TRUNCATE are logged for hot standbys) | 1.5 | 4% | `wal_level = minimal` (no replication then) or fewer truncates |
| diagnostics tables (`tick_log`, `server_tick_log`, ...), `mc.game_state`, the rest | about 2.0 | 5% | unlogging them gained nothing measurable (`top_unl`: 36 against 37 KB) |

**Generating new chunks** (a player exploring), `walgen.sh`, 121 new chunks: **11.8 KB of WAL per chunk**, of which `mc.chunk` 7.1 KB (620 of its 863 KB are full-page images), `mc.chunk_section` 2.3 KB, light 0.8 KB, and the packet cache only **0.3 KB** (the cached packets of
flat chunks compress to a few hundred bytes), so **UNLOGGED `mc.chunk_cache` saves 2.4%: not worth it** (a crash would empty it).  **`wal_compression` cuts it by 46%** (6.4 KB per chunk, `lz4` and `pglz` alike, generation time unchanged).  <<S7-LZ4>>

## Table layout

From the golden database (`inspect.sql`) and the counters of the runs:

* **Queues are already UNLOGGED** (net.inbox/outbox/batch/play_inbox/config_cache/conn, mc.play_in/play_in_work/play_out/kick/visible/block_event/block_actor/pending_ack) and have no index.  **The chunk and player tables are logged** (the world must persist).
* **`mc.player`**: fillfactor 60, four indexes, none on a column that changes every tick: **97-100% of updates are HOT**; the table stays at 192 KB for 200 bots over a whole run.  **`net.conn`**: fillfactor 60, 100% HOT.  `mc.game_state` (one row, updated every tick): 100% HOT, 40 KB.
  These are right as they are; no other fillfactor was found to help.
* **`mc.chunk*`**: fillfactor 70 (+ `toast_tuple_target = 8160` on sections): 14,884 chunks = 153 MB in all (about 10 KB per chunk).
* **Unused indexes in the runs**: `mc.visible_pkey` and `visible_target_idx` (small, used for conflict checks), `mc.player_name_idx` (`lower(name)`, 168 KB at 200 bots, only written when a name changes).  No index on a hot column is unused: nothing to drop.
* **TOAST**: switching the packet columns of the queues and the chunk cache between pglz (default), lz4 and EXTERNAL (never compressed) changed nothing measurable (`chunkpath.sh`: fetching 441 cached chunks 191 / 197 / 162 ms best, within noise; frame + insert 200 / 207 / 212 ms), and EXTERNAL inflates the cache from 5 MB
  to **119 MB**.  Not recommended.
* **Retention**: `mc.tick_log` and `mc.server_tick_log` grow by two rows per tick (about 100 bytes each: 17 MB a day each at 20 ticks a second) and `mc.error_log` by the errors; `sql/450_tuning.sql` adds `mc.prune_logs(keep, chat_keep)` (default 7 days; chat only when asked) to be run from a
  maintenance session outside the tick.  No partitioning: at this rate a week is 120 MB.
* **Payload statistics**: `sql/455_storage_params.sql` sets statistics target 0 on the eight packet payload columns (see WAL).

<<S7-STATS>>

## State tiering for per-player live state

**Question (from the coordinator).**  `mc.player` rows carry fast-changing fields (position, rotation, "what the viewers were last told", keep-alive and visibility bookkeeping) that the tick updates every tick and that generate WAL, while only a snapshot of the position
every N seconds, plus on leave and on important events, needs to be durable.  Is it worth tiering them?  Three layouts, same update pattern, side by side (`tests/bench/tuning/live_state.sh`, `live_state.sql`; 1,200 ticks at 20 Hz, one transaction per tick, a throwaway copy of the golden database,
reference configuration, autovacuum at its defaults):

* **(c) status quo** `wide`: everything in `mc.player` (35 columns, the real indexes, fillfactor 60).  The pattern is the one in `sql/340_game_input.sql` / `sql/330_game_players.sql`: for every mover (a random fraction per tick)
  `x y z yaw pitch on_ground chunk_x chunk_z vis_dirty`, then `sent_qx..last_sent_tick`, the `vis_dirty` clear, every 15 s the keep-alive columns for everybody and the answer on the next tick.
* **(b)** `hot_logged`: the 21 fast-changing columns in a narrow LOGGED table (fillfactor 60, no index on a changing column, so updates stay HOT).
* **(a)** `hot_unlogged`: the same narrow table UNLOGGED, plus a durable snapshot into `mc.player` every N ticks (100 = 5 s, 300 = 15 s) of the players that moved since the last one.

| case (players : fraction moving) | layout | update cost per tick, ms (avg / p99) | **WAL KB per tick** | snapshot cost (when it runs) | dead tuples after the run | table size after the run |
|---|---|---|---|---|---|---|
| 500 : all | (c) wide | 10.1 / 20.5 | **118.8** | - | 14,074 | 4.7 MB |
| 500 : all | (b) narrow logged | 16.0 / 36.4 | **114.7** | - | 8,008 | 1.9 MB hot + 0.2 MB |
| 500 : all | (a) unlogged, snapshot 5 s | 10.3 / 24.9 | **1.1** | 4.2 ms every 5 s | 7,759 + 756 | 2.1 MB hot + 0.3 MB |
| 500 : all | (a) unlogged, snapshot 15 s | 11.8 / 32.1 | **0.8** | 5.4 ms every 15 s | 19,956 + 741 | 5.5 MB hot + 0.3 MB |
| 500 : 25% | (c) | 4.3 / 9.4 | **30.0** | - | 1,481 | 0.5 MB |
| 500 : 25% | (b) | 4.1 / 10.4 | **29.5** | - | 1,660 | 0.4 MB + 0.2 MB |
| 500 : 25% | (a) 5 s | 4.1 / 11.7 | **1.2** | 2.0 ms every 5 s | 802 + 746 | 0.4 MB + 0.3 MB |
| 2,000 : all | (c) | 43.3 / 107.8 | **468.4** | - | 38,148 | 12 MB |
| 2,000 : all | (b) | 34.8 / 82.4 | **459.4** | - | 33,239 | 7.6 MB + 0.7 MB |
| 2,000 : all | (a) 5 s | 32.1 / 89.3 | **3.6** | 8.8 ms every 5 s | 29,777 + 3,052 | 8.0 MB + 1.1 MB |
| 2,000 : 25% | (c) | 11.7 / 21.3 | **119.1** | - | 6,213 | 1.9 MB |
| 2,000 : 25% | (b) | 10.5 / 19.2 | **116.6** | - | 6,588 | 1.5 MB + 0.7 MB |
| 2,000 : 25% | (a) 5 s | 10.2 / 25.1 | **3.5** | 9.0 ms every 5 s | 2,987 + 3,053 | 1.3 MB + 1.1 MB |

(WAL: `pg_stat_wal` over the run divided by the ticks; full-page images were 0-2% of the records in every case.  A `VACUUM` of either table took 30-72 ms at the end of every run: no layout changes the vacuum cost measurably at these sizes.  The update-cost column is
wall-clock on a shared machine: differences of a few ms are noise; the 2,000-player all-moving case is the only one where the unlogged layout looks faster, -26%, from one run each.)

**What it shows**

1. **(b) buys nothing.**  A narrower row does not mean less WAL: the record of a HOT update carries the changed bytes (PostgreSQL already leaves out the unchanged prefix and suffix of the tuple), and the fast columns are the changed ones.  WAL is 115 against 119 KB per tick (-3%);
   the update is not faster.  The narrow table is 60% smaller (1.9 MB against 4.7 MB at 500 players), which only matters for scans.  **Not recommended.**
2. **(a) removes 99% of the player state's WAL**: 119 -> 1.1 KB per tick at 500 players all moving (**2.4 MB/s -> 22 KB/s; 8.6 GB an hour -> 80 MB an hour**), 468 -> 3.6 KB at 2,000.  What remains is the snapshot, and it shrinks with a longer interval (0.8 KB at 15 s).
3. **It does not make the tick faster on this machine**, except possibly at 2,000 players (-26%, one run each): WAL was never the bottleneck with `synchronous_commit = off` on local storage.  What it buys is **disk, backup and replication volume** and cheaper checkpoints.
4. **Share of the whole server's WAL.**  In the steady-state window above the player updates are 31% of 37 KB per tick (`wal1`); with everyone moving they are most of it.

**The durability trade, precisely (variant a)**

* **What is lost on a crash** (PostgreSQL crash, operating-system crash, power loss): the *position, rotation and on-ground flag of players who moved since their last snapshot*, at most **N ticks of movement** (N = 100 is 5 s, average loss 2.5 s; players come back where the last snapshot put them).
  Nothing else: blocks and the world, inventories, health, food, game modes, chat, bans, ops and every other table keep their normal WAL durability (`synchronous_commit = off` still applies to them: up to a few hundred ms).
* **What is not lost:** a clean shutdown (an UNLOGGED table survives it); a player who left (`mc.live_snapshot(uuid)` on leave); a teleport, a death or any event the game chooses to snapshot at once; the last snapshot of everybody.
* **Recovery path** (`mc.live_restore()`, tested in `tests/sql/456_player_live.sql`): crash recovery empties an UNLOGGED table; `mc.live_restore()` rebuilds one live row per player from `mc.player`'s snapshot (positions as of the last snapshot, session ids cleared because every connection died with the
  server), idempotent, to be called once before the gateway starts.  Until then `mc.player_state` (live row if there is one, else the snapshot) answers every read.  A standby promoted after a failover sees the same empty table (unlogged data is not replicated) and the same recovery applies.
* **What it costs in complexity:** every UPDATE of the hot columns in `sql/340_game_input.sql` and `sql/330_game_players.sql` (movement, the `sent_*` bookkeeping, keep-alive, `vis_dirty`) would have to target `mc.player_live`, `mc.on_join` would insert the live row and `mc.on_leave` would snapshot and delete it, and
  the tick would call `mc.live_snapshot()` every N ticks.  Those are other modules' files: **only the opt-in prototype `sql/456_player_live.sql` exists (nothing uses it)**: `mc.live_state_enable(unlogged)`, `mc.live_snapshot([uuid])`, `mc.live_restore()`, the `mc.player_state` view, `mc.live_state_disable()`.
* **Not measured:** the end-to-end tick with the game code rewired (the benchmark isolates the table layout with the real update pattern), and a real crash (the unlogged behaviour after `kill -9` is PostgreSQL's documented one; the test simulates it with `TRUNCATE`).

**Decision for the user.**  If the WAL volume of per-player movement matters to you (disk, backups, replication; it does at 500+ moving players), take (a) with a 5-10 s snapshot and accept "after a crash players return up to N seconds back".  If it does not (a small server), keep (c): it is
simpler and the tick time is the same.  (b) is never worth it.

## Recommended configuration

`docker/postgresql.conf` (server level) and `sql/450_tuning.sql` / `sql/455_storage_params.sql` (database level), with the **risk of every non-default setting**:

| setting | value | why (evidence) | risk |
|---|---|---|---|
| `fsync` | on | `off` is -6 ms but a crash can corrupt the cluster | none: this is the safe choice |
| `synchronous_commit` | **off** (server and database) | no tick-time gain measured on local NVMe-class storage; it keeps a slow flush (network disk) out of every tick | after an OS crash or power loss the last few hundred ms (`wal_writer_delay` 200 ms, up to 3 rounds) of committed ticks can be lost; the cluster is **never** corrupted.  Set `on` where zero loss matters more |
| `full_page_writes` | on | off saves 16% WAL, no time | torn pages after power loss |
| `wal_level` | replica (default) | `minimal` saves 4 KB of 37 per tick | `minimal` forbids base backups and replication |
| `wal_compression` | <<S7-WALC>> | -46% WAL for chunk generation (full-page images) | CPU on the tick's path |
| `shared_buffers` | **128MB** | larger makes every commit slower (cause 3); the OS page cache holds the world | misses read from the OS cache (microseconds); raise it only after the truncates leave the tick |
| `work_mem` | 64MB | 20 simultaneous joiners spill 30 MB at 4-16 MB | up to 64 MB per sort/hash node: with a handful of sessions no concern |
| `maintenance_work_mem` | 128MB | vacuum, index builds | none |
| `max_wal_size` / `min_wal_size` / `checkpoint_timeout` / `checkpoint_completion_target` | 4GB / 512MB / 15min / 0.9 | checkpoints do not change the tick (s5); fewer checkpoints -> fewer full-page images (-14% WAL) | crash recovery replays up to 15 min of WAL: seconds |
| `jit` | off (server and database) | +8 ms and 3x the ticks over 100 ms when on | none for this workload |
| `max_parallel_workers_per_gather` | 0 (server and database) | no gain, start-up cost per short statement | a large analytic query run by hand would not parallelise: `set` it for that session |
| `random_page_cost`, `effective_cache_size` | 1.1, 4GB | planner hints for the big world tables; no tick effect measured | none |
| `autovacuum_naptime` | **10s** | queue tables 5.5 MB instead of 53 MB, tick -4 ms | a vacuum worker looks at the database every 10 s: negligible; more analyze WAL (fixed by `sql/455`) |
| `idle_in_transaction_session_timeout` | **10s** (server and database) | one idle transaction: 3x slower within 30 s | kills an admin's idle session after 10 s; `set ... = 0` for it |
| `track_io_timing`, `track_activities` | defaults (off / on) | +2.6 ms when on / no gain when off | - |
| logging | `log_checkpoints`, `log_autovacuum_min_duration = 1s`, `log_lock_waits`, `log_temp_files = 8MB`, `log_min_duration_statement = 250ms` | what is needed to find a slow tick afterwards | a little log volume |
| `huge_pages` | try | none were available to test | none |
| column statistics of payload columns | target 0 (`sql/455`) | 16% of the WAL <<S7-STATSV>> | the planner has no statistics on columns it never uses |
| `tools/janitor.sh` | with the development gateway | queues 65 MB -> 5 MB, ticks -4 ms | a session of its own; skip it for an external gateway |

## What did not help

`synchronous_commit = on` (no cost measured, so no gain from `off` either on this disk), `wal_level = minimal`, `full_page_writes = off` (WAL only), `wal_writer_delay`, `bgwriter_*`, `work_mem` at 200 bots, `max_parallel_workers_per_gather`, `random_page_cost` / `effective_cache_size`, `plan_cache_mode`
(worse), `autovacuum_naptime = 5s` with no cost delay in the in-procedure loop (worse), per-table autovacuum thresholds on the queues, UNLOGGED diagnostics and chunk cache, TOAST storage modes (pglz / lz4 / EXTERNAL), `track_activities = off`, more frequent checkpoints (harmless, +WAL), a narrower LOGGED hot table, a larger `shared_buffers`.

## Container packaging

`docker/` (Dockerfile on `postgres:16` + `postgresql-plpython3-16`, `entrypoint.sh`, `initdb.d/10-dbcraft.sh`, `postgresql.conf`, README) and `docker-compose.yml` (ulimit nofile 65536, shm_size, ports, the read-only mounts for the generator reports and a vanilla capture; Mojang data is never in the image or in git).
**Docker is not available where this was written (a client, no daemon), so the image was not built and the compose file was not run.**  <<VALIDATE>>

## Operating-system notes (documentation only, not tested)

* **Open files**: `LimitNOFILE=65536` (systemd) or `ulimit -n`; the development gateway holds one socket per player in one backend and the default 1024 stops it near 1,000 players (it failed with `Too many open files` at 1,000 during `docs/SQL-GATEWAY.md`).
* **Transparent huge pages**: `madvise` (the Linux default on this host) is fine; `always` can add latency spikes to a database.  If you reserve huge pages (`vm.nr_hugepages`), `huge_pages = try` will use them.
* **`vm.swappiness`** low (1-10), no swap on the database host if possible; **CPU governor** `performance`; **I/O scheduler** `none` or `mq-deadline` on NVMe.
* **Storage**: an fsync on this host's virtual disk is about 0.09 ms, but the shared ext4 volume stalled for 100-300 ms now and then (cause 8).  Put the data directory (and ideally `pg_wal`) on local NVMe, not on a network disk.

## Reproduce

```
tests/bench/tuning/prepare.sh                                   # the golden data directory (about 4 min)
tests/bench/tuning/run.sh NAME ref,av_nap10 200 0.25 100        # one trial; MODE=top for gateway style; see the header of run.sh for APPLY/STALL/JANITOR/DIAG/WALSTAT
tests/bench/tuning/matrix.sh TAG 3 100 200 0.25 'a=ref' 'b=ref,av_nap10|MODE=top;STALL=1'     # interleaved repetitions; then table.py TAG, qsize.py TAG
tests/bench/tuning/live_state.sh 1200                           # state tiering
tests/bench/tuning/truncate_cost.sh ; chunkpath.sh ; drain_mem.sh ; walgen.sh ; xmin_probe.sh 45 200
tests/bench/tuning/validate_docker.sh                           # the container pieces without a Docker daemon
DBCRAFT_TESTDB=dbcraft_tuning tests/sql/run.sh                  # the SQL suite (450, 455 and 456 are the new tests)
```
