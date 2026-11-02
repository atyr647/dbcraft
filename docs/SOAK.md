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

RESULTS_PLACEHOLDER
