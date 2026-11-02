# Soak: why 200 walking players were all kicked after about four minutes

The scoreboard (`docs/SCOREBOARD.md`) found that with 200 walking players **every client got `disconnect.timeout` within a few seconds of each other, about four minutes in**,
while vanilla completed the ten-minute run.  The gateway loop time had climbed from 3 ms to about 85 ms while the SQL tick stayed near 30 ms, and the scoreboard's leading
guess was "the PL/Python development gateway degrades with time".  That guess was partly right and partly wrong.  This document is the reproduction, the evidence, the
**two** root causes, the fixes and a guard.

## Reproduction

```
DBCRAFT_PGDATA=/tmp/dbcraft-pg-soak DBCRAFT_PGPORT=54744 tests/e2e/setup.sh            # an own cluster + database + dev gateway
python3 tools/soak/soak.py --kind plpython --setup --n 200 --minutes 8 --sample 20     # the scoreboard's scenario, sampled every 20 s
python3 tools/soak/report.py /tmp/soak-samples.jsonl                                   # the table below
```

`tools/soak/soak.py` pre-generates the area, starts the gateway (`plpython` = `call net.run(port)`, `rust` = `gateway/target/dbcraft-gateway`) and two chunk generators,
runs the scoreboard's load generator (`tools/scoreboard/loadgen.py`: real login, keep-alive and chunk-batch answers, 4.3 blocks/s walking inside +-500 blocks, view distance 10)
and samples every 20 s (`tools/soak/sample.sql`): tick time by phase, the gateway loop time, size/dead tuples/vacuum counts of every table, the oldest snapshot and
transaction, wait events, locks, checkpoints, WAL, the gateway's memory, the keep-alive state, and catalog size.

## Evidence (baseline: the code as merged, PL/Python gateway, 200 walking players)

| t (s) | players | SQL tick (ms) | `net.process` (ms) | gateway loop (ms) | keep-alive pending | `net.outbox` (MB) | `net.inbox` (MB) | `mc.chunk_wanted` (MB) |
|---|---|---|---|---|---|---|---|---|
| 40 | 201 | 253 | 214 (joins) | 11.8 | 0 | 952 | 2.5 | 0 |
| 81 | 201 | 38 | 5.1 | 12.5 | 0 | 1,037 | 23 | 10 |
| 121 | 201 | 37 | 6.5 | 16.0 | 0 | 1,159 | 44 | 17.5 |
| 161 | 201 | 41 | 11.2 | 46.0 | 0 | 1,210 | 65 | 24.6 |
| 201 | 201 | 32 | 18.6 | 66.0 | **201** | 1,223 | 80 | 27.0 |
| 261 | 201 | 40 | 25.8 | 89.6 | 201 | 1,223 | 99 | 27.1 |
| 322 | 201 | 41 | 31.3 | 89.9 | 201 | 1,223 | 134 | 27.1 |
| 342 | **0** | 104 | 28.2 | 54.0 | 0 | 1,230 | 134 | 27.1 |
| 422 | 0 | 36 | **27.6** | **76.2** | 0 | 1,230 | 134 | 27.1 |

All 200 clients were dropped at the same second (339.5 s) with `disconnect.timeout`.  Two things in the table are the whole story:

1. **The cost does not come from the work.**  At 342-442 s there is nobody connected and the queues are empty, yet every tick still spends 28-32 ms in `net.process` and the
   gateway loop takes 54-76 ms.  What costs that time is the *heap*: `net.inbox` has 134 MB of pages and `net.outbox` 1.2 GB, all of it dead rows.
2. **The keep-alive answers were not unanswered, they were late.**  From 201 s on all 201 players show a pending keep-alive, but the age of the oldest pending one stays below
   450 ticks (`mc.keepalive_due` kicks at 600): rounds were being answered, 10-30 s late.  Then one round exceeded the limit for everybody at once.

## Root cause 1: the DELETE-per-tick queues bloat, and nothing ever gives the space back

`net.drain_outbox()` empties `net.outbox` with `DELETE ... RETURNING` every tick, `net.process` does the same to `net.inbox`.  A DELETE leaves dead rows until a vacuum;
both statements then read **every page of the heap, live or not**.  A login burst alone (200 joiners at view distance 10: 216 KB of configuration plus about 4 MB of chunks each)
pushes ~1 GB through `net.outbox` in 20 s and the heap never shrinks (`net.inbox` grows by 10 MB per 20 s from the clients' `client_tick_end`/move packets).  Each tick therefore
scans a heap that only gets bigger: the loop time rises linearly and then crosses the 50 ms tick, the tick rate falls below 20 per second, and keep-alive answers queue up.

Why did nothing vacuum?  `sql/435` left these two queues to autovacuum ("shared with the gateway, so the tick cannot truncate them safely") and said so:
`autovacuum_naptime = 1s` is required.  Two things break that assumption:

* The default `autovacuum_naptime` is one minute.
* **A backend only reports its table statistics when it goes idle, and the PL/Python gateway is one long `CALL` that never does.**  Proved with
  `tests/soak/stats_flush_probe.sql`: a procedure that updates a table and `plpy.commit()`s 20 times a second for 12 seconds is invisible to every other session while it runs
  (`n_tup_upd = 0`, `n_dead_tup = 0`, also with `pg_stat_force_next_flush()` after every statement); 23,300 updates appear in one lump when the CALL ends.  Autovacuum cannot see
  what it never hears about.  The sample table shows it as `dead tuples reported: net.outbox 0` next to a 1.2 GB outbox.

## Root cause 2: the dev gateway stopped reading its sockets once a tick overran

The PL/Python loop reads sockets "until the tick is due": `left = deadline - now; if left <= 0: break`.  When one iteration overruns, the next iteration starts with its deadline
already in the past, breaks out of the I/O phase at once, runs the tick on whatever it has and overruns again.  **Under sustained overload the gateway never reads a socket at all**:
keep-alive answers wait in the kernel buffers until the loop happens to catch up, which is how replies became 10-30 s late and then 600 ticks old for everybody.  This amplifier turns
"slow ticks" into "everybody kicked".  Root cause 1 was only what made the ticks slow.

The Rust gateway does not have this flaw: every iteration calls `epoll_wait` (timeout 0 when late) and serves the readable sockets *before* it runs the tick.

## Fixes

| Fix | Where | What |
|---|---|---|
| Queue trimming | `sql/780_queue_trim.sql` (`net.trim_queue`, `net.trim_queues`, `net.drain_outbox`) | right after the drain, the one moment the queues are empty (the same transaction consumed them), a queue whose **total** size (heap + TOAST + indexes) exceeds `dbcraft.queue-trim-bytes` (default 8 MiB) is `TRUNCATE`d, never waiting for a lock (`NOWAIT`) and never when a row is waiting.  No vacuum involved, no `reltuples = 0` statistic (`sql/435`).  Covers both gateways. |
| Dev gateway I/O | `sql/optional/dev_gateway.sql` | always one pass over the ready sockets, even when the tick is late |
| Janitor | `tools/janitor.sh` | vacuums the tables that grow by DELETE/UPDATE and that the trimming does not cover (`mc.chunk_wanted`, `mc.chunk_request`, `mc.visible`, the tick logs ...); the queues are no longer in its list.  **Required next to the PL/Python gateway** (autovacuum is blind to it in principle) |
| Maintenance thread | `gateway/src/maint.rs`, settings `maintenance_s` (5) and `maintenance_tables` | the Rust gateway runs that janitor itself on a connection of its own, in a thread (a VACUUM cannot run in the tick's transaction and must not delay a tick) |
| Guard | `tests/soak/run.sh`, `tools/soak/soak.py --check` | see below |
| Regression test | `tests/sql/780_queue_trim.sql` | bloat is reproduced, trimmed, never loses a row, the drain returns every byte and trims, 0 disables |

## A third finding: vacuuming a table the tick TRUNCATEs stalls the tick

The first fixed run still had two 5-second stalls (ticks 10900 and 11240).  `tools/janitor.sh` vacuumed `mc.play_out`; the tick `TRUNCATE`s `mc.play_out` every 20th
tick, and a TRUNCATE needs ACCESS EXCLUSIVE, which waits behind the vacuum's lock.  Rule, now written into `tools/janitor.sh` and `gateway/src/config.rs`: **never vacuum a
table the tick truncates** (`mc.play_out`, `mc.play_in_work`, `net.batch`, `mc.pending_ack`, `mc.block_actor`).  `net.inbox`, `net.outbox` and `mc.play_in` are not vacuumed
either: `net.drain_outbox()` trims them (sql/780).

## Results after the fixes (200 walking players, view distance 10, 20 minutes, PL/Python gateway + `tools/janitor.sh`)

`tests/soak/run.sh` / `tools/soak/soak.py --check`: **RESULT: PASS** (0 clients dropped, every queue under 16 MB, no growth).  Other workers' test suites ran on the same
machine during the first minutes (load average 3-9), so the first five minutes are slower than the rest; that is the login burst (201 joiners at view distance 10) competing
with two chunk generators, not a trend.  One sample per minute (full data: `tools/soak/report.py /tmp/soak-proof-plpy.jsonl`):

| t (s) | players | SQL tick (ms) | gateway loop (ms) | ticks/s | `net.outbox` (MB) | `net.inbox` (MB) | `mc.play_out` (MB) | gateway RSS (MiB) |
|---|---|---|---|---|---|---|---|---|
| 60 | 201 | 78 | 78 | 9.6 | 6.9 | 4.3 | 5.6 | 156 |
| 120 | 201 | 59 | 80 | 12.1 | 7.8 | 2.0 | 0.0 | 156 |
| 180 | 201 | 132 | 286 | 9.5 | 4.4 | 8.2 | 7.3 | 159 |
| 241 | 201 | 132 | 405 | 8.0 | 0.0 | 5.9 | 3.9 | 163 |
| 301 | 201 | 43 | 55 | 18.8 | 0.0 | 3.8 | 0.0 | 163 |
| 361 | 201 | 39 | 47 | 20.0 | 6.4 | 0.0 | 0.0 | 163 |
| 421 | 201 | 37 | 40 | 20.0 | 6.2 | 7.7 | 0.0 | 164 |
| 481 | 201 | 36 | 26 | 19.6 | 6.8 | 5.5 | 2.5 | 164 |
| 542 | 201 | 31 | 35 | 19.7 | 4.1 | 3.2 | 0.0 | 164 |
| 602 | 201 | 34 | 35 | 20.0 | 0.0 | 0.0 | 0.0 | 164 |
| 662 | 201 | 33 | 32 | 20.0 | 5.1 | 7.1 | 0.0 | 164 |
| 722 | 201 | 36 | 20 | 17.9 | 0.0 | 4.7 | 0.0 | 164 |
| 782 | 201 | 35 | 32 | 19.3 | 7.1 | 2.5 | 2.3 | 164 |
| 842 | 201 | 28 | 27 | 20.0 | 5.2 | 0.0 | 0.0 | 164 |
| 902 | 201 | 27 | 22 | 20.0 | 6.3 | 6.6 | 0.0 | 164 |
| 963 | 201 | 28 | 32 | 20.0 | 7.2 | 4.3 | 0.0 | 164 |
| 1023 | 201 | 27 | 28 | 20.0 | 5.0 | 2.0 | 0.0 | 164 |
| 1083 | 201 | 28 | 24 | 20.0 | 7.3 | 8.0 | 0.0 | 164 |
| 1143 | 201 | 25 | 27 | 20.0 | 7.4 | 5.6 | 0.0 | 164 |
| 1203 | 201 | 32 | 23 | 19.5 | 4.9 | 3.4 | 0.0 | 164 |

The queues saw-tooth between 0 and the 8 MiB bound instead of reaching 1.2 GB; the tick time **falls** from minute 5 to minute 20 (36 ms to about 27 ms) and the
slow first five minutes are the login burst.  Baseline for comparison: all clients dropped at 339 s with the loop at 90 ms and 1.4 GB of queues.  The same scenario
with the Rust gateway (8 minutes, maintenance thread on by default): PASS, 201 players, tick 100 ms during the join burst and 31 ms at the end, queues 5-19 MB.

## The guard

```
tests/soak/run.sh [plpython|rust] [MINUTES=10] [CLIENTS=200]
python3 tools/soak/soak.py --kind rust --setup --check --n 200 --minutes 20      # the driver itself, own cluster via DBCRAFT_PGPORT
```

It fails (exit 1) when the SQL tick or the gateway loop time of the last quarter of the steady state is more than `--max-growth` (default 2.0, `SOAK_MAX_GROWTH`) times
that of the first quarter, when any client drops (`--allow-drops`, default 0), or when a queue table (`net.inbox`, `net.outbox`, `mc.play_out`, `mc.play_in`,
`mc.play_in_work`, `net.play_inbox`, `net.batch`) exceeds `--max-queue-mb` (default 64, `SOAK_MAX_QUEUE_MB`).  It is sensitive to a loaded machine: judge it on a quiet one.
The unit-level guard is `tests/sql/780_queue_trim.sql` (bloat reproduced, trimmed, no row lost).

## Requirements and remaining risks

* **PL/Python dev gateway: run `tools/janitor.sh` next to it.**  The statistics blindness is in principle unfixable inside one long CALL.  The queue trimming (sql/780) keeps
  the server alive without it, but `mc.chunk_wanted`, `mc.visible`, `net.conn` and the logs then depend on autovacuum, which never hears about them.
* The Rust gateway runs its own maintenance thread (`maintenance_s`, `maintenance_tables`); with it off, use the janitor or `autovacuum_naptime = 1s`.
* Queue trimming assumes **one gateway session**; with several gateways set `dbcraft.queue-trim-bytes = 0` and vacuum the queues instead.
* A TRUNCATE invalidates cached plans that mention the table: it happens once per trim (every few seconds at this load) and costs a re-plan, visible as the 51 ms `drain`
  samples in the early runs.  A larger bound trades memory for fewer trims.
* `net.drain_outbox_ref()` (opt-in experimental variant) does not trim.
* Not measured: runs longer than 20 minutes, more than 200 players, a quiet machine (load was 3-9 from other workers, so absolute times are pessimistic), and the Rust
  gateway for 20 minutes (8 minutes only).
