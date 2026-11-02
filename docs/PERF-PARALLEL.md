# Can parallel query speed up the tick?

> Update: this note is about Postgres's own parallel query (still neutral or slower). Using SEVERAL CONNECTIONS (sharded movement, the entity simulation on its own connection) was
> re-measured on a quiet machine in docs/PERF-MULTICORE.md, with different results.

**Short answer: no, not on PostgreSQL 16 and not for tick-sized work.** The tick uses one core while three idle. This note measures the ceiling of using Postgres's own parallel
query (and two substitutes) on those idle cores, and finds that every variant is neutral or slower. Nothing was built into `sql/`; everything here is a measurement
script under `tests/bench/parallel/`.

Measured on: PostgreSQL 16.15, 4 vCPUs (Xeon 2.1 GHz), `jit = off`, the 500- and 2,000-player synthetic walks of `tests/bench/tick/` (warm world, view distance 10 and 5).
**The machine was shared with three other workers the whole time (load average 2.0 to 3.5 on 4 CPUs)**, so wall times carry 10% to 30% noise (the same 2,000-player run took 149 ms and
195 ms in two repeats). Ratios between interleaved runs and the fixed costs (worker startup) are more trustworthy than absolute numbers.

## 1. Where the time goes, and what can possibly be parallel

500 players all moving: 38.7 to 41.4 ms per tick. 2,000 players, view distance 5: 149 to 157 ms (game phase 114 to 120 ms).

`pg_stat_statements` (nested) puts the heavy statements in three groups (`tests/bench/parallel/classify.py`):

| Group | Parallel query possible? | 500 players | 2,000 players |
|---|---|---|---|
| Data-modifying statements (`INSERT`/`UPDATE`/`DELETE`, also as CTEs): the movement broadcast, visibility add/remove, queue moves, drain, chunk fan-out | **never** on PG16 (see section 2) | broadcast statement 13.2 ms, drain 2.2+2.4, chunk streaming 7.9, inbox 2.2, play_out->outbox 2.1 ... | broadcast 69.4, visibility deletes 17, drain 10.8, chunk streaming 17.2, inbox 8.2 ... |
| Read-only SELECTs run by PL/pgSQL with `SELECT ... INTO` / assignment | no workers (row limit), but could be turned into `EXECUTE` | move decode 2.4, visibility pair search 0.8 | move decode 8.9, visibility pair search 6.4 |
| Read-only compute *inside* a data-modifying statement | only if separated out of it | in the broadcast: packet build 3.1, join 2.2, sort 3.1, grouped `string_agg` 0.9 = **9.3 ms** | packet build 16, join 15, sort 23, aggregate 4 = **58 ms** (plan times include `auto_explain` overhead, about 25%; standalone: 42 ms) |

So the separable read-only compute is about **15 ms of 40 at 500 players (37%) and 63 ms of 150 at 2,000 (42%)** (sum of the broadcast compute, the decode, the pair search and
small SELECTs). Everything else is DML and cannot go parallel as it stands. Both numbers are upper bounds for what parallelism could touch.

## 2. The rules, verified on this server (`tests/bench/parallel/exp9_rules.sql`)

| Statement shape | Workers launched? |
|---|---|
| plain `SELECT` | yes (3 of 3) |
| `CREATE TABLE AS SELECT` (also into a temp table) | yes |
| `INSERT ... SELECT` (no data-modifying CTE) | **no**: the plan is serial under the `Insert` |
| a `WITH x AS (INSERT/UPDATE/DELETE ...)` statement (the shape of the tick's statements) | **no** |
| PL/pgSQL `PERFORM select ...` | yes |
| PL/pgSQL `SELECT ... INTO v` | **no**: the plan has a `Gather` but `Workers Launched: 0` (row limit) |
| PL/pgSQL `v := (select ...)` | no `Gather` in the plan at all |
| PL/pgSQL `FOR r IN select ...` | no `Gather` (cursor) |
| `EXECUTE 'select ...'` (dynamic SQL), with or without `INTO` | **yes**: 3 of 3 workers, also with `INTO` (the result is captured, no `CREATE TABLE AS` needed) |

Parallel-safety of the functions: the codec and packet builders (`proto.*`, `mc.quant`, `mc.angle_byte`, `mc.pkt_*`) are `PARALLEL SAFE` (149 functions in `mc`, `net`, `proto`);
`mc.chunk_packet` (writes the cache), `net.frame` and `net.player_info_body` are `PARALLEL UNSAFE`, 133 functions in all. A `MATERIALIZED` CTE is a barrier (CTE scans are parallel restricted).

## 3. The fixed cost: launching workers (`exp5_floor.sql`)

A trivial query (`count(*)` over 2,000 rows) with 0 to 3 workers allowed, 31 runs each, on a machine with idle cores:

| Workers | median | p10 |
|---|---|---|
| 0 | 0.072 ms | 0.069 ms |
| 1 | 5.32 ms | 4.98 ms |
| 2 | 5.86 ms | 5.46 ms |
| 3 | 6.85 ms | 6.34 ms |

**Every parallel statement costs 5 to 7 ms before it does any work** (fork of the workers, shared-memory setup, teardown; PG16 has no persistent worker pool). At 500 players the
tick runs 93 distinct statements (1,244 executions per tick counting the bodies of helper functions that `pg_stat_statements` tracks as nested statements); 15 of them take more than 1 ms
per tick in total and only 3 more than 5 ms (that count includes the wrapper rows that contain the others).

Break-even: with 3 workers and perfect scaling a statement of serial length T saves 0.75 T minus about 6.5 ms, so T must exceed about 9 ms to gain anything and about 23 ms to gain 10 ms.

## 4. Standalone speedups of the read-only computations (medians of 21 runs, planner costs forced to 0 so a parallel plan is always chosen)

500 players, packets in a 500-row work table (`exp1.sql`, `exp2.sql`):

| Computation | serial | 3 workers | speedup |
|---|---|---|---|
| floor: `count(*)` | 0.04 ms | 5.7 ms | 0.01x |
| packet build for 500 movers | 3.96 ms | 17.7 ms | 0.22x |
| fan-out: visible x packets, `string_agg(... order by)` per viewer | 5.48 ms | 12.99 ms | 0.42x |
| same, `array_agg` | 7.88 ms | 13.71 ms | 0.57x |
| join only (count) | 1.25 ms | 10.25 ms | 0.12x |
| visibility pair search, all 500 dirty (join storm) | 13.97 ms | 26.36 ms | 0.53x |

2,000 players:

| Computation | serial | 3 workers | speedup |
|---|---|---|---|
| fan-out, `string_agg(... order by)` | 28.3 ms | 24.7 ms | **1.15x** |
| same without `ORDER BY` in the aggregate | 12.3 ms | 16.6 ms | 0.74x |
| `array_agg` | 31.2 ms | 28.4 ms | 1.10x |
| join only | 5.7 ms | 8.5 ms | 0.67x |

Why the fan-out scales so badly even at 2,000 players: its parallel plan is a *parallel hash join and sort in the workers, then a `Gather Merge` of 45,000 tuples into the leader, which runs
the `GroupAggregate` serially*. An aggregate with `ORDER BY` inside cannot be split into partial aggregates, so the funnel stays.

### CPU-bound scaling with a tiny result (`exp7_scaling.sql`)

| Work | 0 workers | 1 | 2 | 3 |
|---|---|---|---|---|
| packet build of 2,000 movers (12.9 ms of work) | 12.9 ms | 11.5 | 16.8 | 20.1 |
| the same x10 (134 ms of work) | 133.9 ms | 84.3 (1.6x) | 59.2 (2.3x) | 73.4 (1.8x) |

Work of 13 ms never gets faster; work of 134 ms reaches 2.3x with 2 workers (3 workers compete with the other jobs for the 4 CPUs here). Nothing in a 50 ms tick is that large.

## 5. Structural workarounds, with data

**Layouts that let each worker aggregate whole viewers** (`exp3.sql`, `exp4.sql`, 2,000 players). Serial / 3 workers:

| Variant | serial | 3 workers |
|---|---|---|
| `mc.visible` as is | 24.6 ms | 30.5 ms |
| copy hash-partitioned by `viewer_conn` (8 partitions), `enable_partitionwise_aggregate` | 23.3 ms | 30.9 ms (the planner did not use partitionwise aggregation: the join with the unpartitioned packet table sits between the scan and the aggregate) |
| index on `(viewer_conn, target_eid)` (ordered scan, no sort) | 25.3 ms | 30.9 ms; the serial index plan alone takes 34 ms (45,000 Memoize probes) |
| correlated aggregate per connection over `net.conn` | 22.7 ms | 33.2 ms |
| `LATERAL` per connection | 12.1 ms | 28.0 ms |

Every variant is slower in parallel (0.4x to 0.8x). (The serial rows scatter between 12 and 25 ms across runs of the same query: that is the load noise.)

**(a) The compute phase as parallel-eligible `CREATE TABLE AS` statements** (`exp6_ctas.sql`, 2,000 players): packets into a work table, then fan-out into a second work table, dropping both afterwards.

| Variant | median | p10 |
|---|---|---|
| today's shape: one serial statement with a materialised CTE | 35.0 ms | 26.1 ms |
| two serial `CREATE TABLE AS` statements | 84.5 ms | 68.8 ms |
| two `CREATE TABLE AS` statements with 3 workers | 90.0 ms | 72.3 ms |

Step times with 3 workers: first statement 28.7 ms, second 40.1 ms, drops 2.3 ms. The statistics-free work tables were not the cause (the plan is the same shape). Creating and dropping relations per
tick is also exactly the file churn the tuning work found to be the main cause of slow ticks. A persistent work table does not help: `INSERT ... SELECT` into it is serial (section 2).
The cheaper capture, `EXECUTE ... INTO` a plpgsql variable, avoids the table, but the funnel and the startup cost remain.

**(b) Pipeline parallelism: a second connection computes tick N-1's fan-out while the tick connection runs tick N.** Overlap potential by arithmetic: the fan-out compute is 37% to 42% of the tick, so
the leader could drop from 150 ms to about 85 ms at 2,000 players (1.8x) and from 40 ms to about 25 ms at 500, if the helper kept pace and its work were free. I could not measure the
contention honestly: running a helper at 20 iterations per second next to the 2,000-player tick gave 157.6 ms against 149.4 ms alone (+5.5%), but a repeat of the "alone" run came out at 194.7 ms (other jobs),
and the helper itself needed 70.9 ms per iteration (schedule lag 45 ms) because the CPUs were busy. **What it would cost in behaviour**: other players' movement would reach the client one tick (50 ms) later than
vanilla sends it, the visible set would have to be snapshotted consistently with the packets (entities appearing and leaving between ticks), and the helper's `play_out` rows would have to be ordered against
the leader's packets for the same connection. That is a deviation from vanilla and a consistency protocol, for at most 1.8x at 2,000 players. Region sharding measured 2.3x to 2.6x at 2,000 players
(`docs/PERF-TICK.md`) without the latency change, so it is the better use of the cores if more than one is wanted.

**(c) A persistent worker pool through `dblink`** (contrib, available; `pg_background` is not): connections `h0..h3` opened once and driven with `dblink_send_query`/`dblink_get_result`, the fan-out split by
`viewer_conn mod M`, packets passed as parameters (they are uncommitted state in the real tick; the committed `mc.visible` is read by the helpers), results returned as hex text and parsed back (`exp8_dblink.sql`),
2,000 players, same bytes as the local run (855,498):

| | median | p10 |
|---|---|---|
| local, serial (reference, same function) | 58.9 ms | 32.5 ms |
| 1 helper | 39.6 ms | 34.0 ms |
| 2 helpers | 40.1 ms | 31.0 ms |
| 3 helpers | 32.3 ms | 29.1 ms |
| 4 helpers | 31.3 ms | 26.0 ms |

At best 1.25x on the compute that is 42% of the tick, i.e. about 8% of the tick; the leader pays for formatting 80 KB of literals per helper and decoding about 1.7 MB of hex text.

## 6. The whole tick with parallel query switched on (500 players, all moving, wall time, interleaved)

| Setting | tick avg | notes |
|---|---|---|
| parallel off (the tuned default, `max_parallel_workers_per_gather = 0`), run 1 | 41.4 ms | |
| parallel off, run 2 | 40.3 ms | (38.7 ms in the first profile run) |
| 3 workers allowed, **stock planner costs and thresholds** | 39.5 ms | no statement qualifies: the plans are unchanged |
| 3 workers allowed, **costs forced to 0** (every parallel plan taken) | **121.8 ms** | block-handling phase 0.2 -> 31.4 ms, chunk streaming 8.2 -> 54.6 ms: many small statements each pay the 5 to 7 ms launch |

Switching it on is harmless at default costs and ruinous when forced; there is no setting that helps.

## 7. Ceiling by Amdahl, and the decision

Separable read-only compute S (section 1), best case perfect 4-way scaling and free startup, then with the measured startup (5.3 to 6.9 ms) paid by the three statements that would have to be
parallel (broadcast compute, move decode, pair search), then with the measured efficiency of the biggest one (1.15x):

| | S | tick now | ideal (no startup) | with 3 x startup | at measured efficiency |
|---|---|---|---|---|---|
| 500 players | 15 ms | 40 ms | 29 ms (1.38x) | 47 ms (**0.85x**, slower) | about 1.0x |
| 2,000 players | 63 ms | 150 ms | 103 ms (1.46x) | 121 ms (1.24x) | 1.0x to 1.1x |

**Decision: do not build it.** The criteria were at least 1.5x at 2,000 players or at least 25% at 500; even the zero-overhead ceiling is 1.46x and 1.38x, and with the measured startup cost the
500-player tick gets slower. No variant tried beat serial by more than 1.25x. Keep `max_parallel_workers_per_gather = 0` for the tick role (already so in `sql/450_tuning.sql`).

Where parallel query *could* still pay (hypotheses, not measured here): single statements that run more than about 25 ms serially, such as a join storm's pair search with thousands of dirty players,
a `generate_batch` of many chunks, or large bulk edits. These can be run through `EXECUTE ... INTO` or `CREATE TABLE AS` by a function that sets the parallel parameters for that statement only (`set_config(..., true)`),
leaving the rest of the tick serial. Measure first: the break-even length is about 9 ms and the useful length about 25 ms.

## 8. Files and how to reproduce

`tests/bench/parallel/`: `harness.sql` (timing function `par.bench`, `par.workers_used`, the packet view), `exp1.sql` .. `exp9_rules.sql` (the experiments above), `classify.py` + `dump_stmts.sql` (statement classification), `explain_view.sh`
(`tests/bench/tick/explain.sh` with the view distance), `helper.sql` (pgbench helper loop), `safety.sql` (parallel-safety markings). Setup: `DBCRAFT_PGDATA=/tmp/dbcraft-pg-par DBCRAFT_PGPORT=54455 tests/e2e/setup.sh`,
generate the walk area (`mc.generate_flat_area('minecraft:overworld', -15, -15, 115, 115)`), preload `pg_stat_statements`, then `tests/bench/tick/run.sh 500 100 1.0 100 label` (`VIEW=5` for 2,000 players), then `psql -f` the experiment files.
No file in `sql/` was changed; the test suite (29 files, structural guards included) passes on this branch.
