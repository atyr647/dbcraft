# Tick performance

What was measured, what was changed in `mc.server_tick()`, what did not work, why parallel writers scaled so badly in the database comparison, and where the tick stands.
All changes are SQL in `sql/430`-`sql/437` (and in-place edits of `sql/220` and `sql/430_chunk_queue.sql`, see "Relation-file churn"); every rewritten function is compared with the original on random states by `tests/sql/431_tick_perf_moves.sql`,
`tests/sql/432_tick_perf_world.sql` and `tests/sql/437_tick_churn.sql`, and the whole suite (1,207 checks at the last run, 64 + 115 of them these) passes.  The e2e comparison with vanilla (`tests/e2e/run_all.sh`) was **not** run here.

## Result

500 simulated players over 100 x 100 chunks (about 19 viewers each), view distance 10, warm world (every chunk generated and cached), the synthetic walk of
`tests/bench/integration/bench.sql` through the whole pipeline (`net.inbox` -> `mc.server_tick()` -> read of `net.outbox`).  Medians of **interleaved** runs (baseline, new, baseline,
new ...; 4-5 runs of 100 ticks, the first 20 ticks dropped); ranges in `tests/bench/tick/ab.sh` output.  The machine is 4 vCPUs shared with other jobs (see "Noise").

| Scenario | | tick avg | p10 | p50 | p99 | on-CPU avg |
|---|---|---|---|---|---|---|
| 500 players, all moving | baseline | 81.1 ms | 63.1 | 78.9 | 121.5 | 60.5 |
| | now | **39.4 ms** | 30.4 | 37.6 | **64.6** | 28.9 |
| 500 players, 20% moving | baseline | 57.0 ms | 39.8 | 55.5 | 103.2 | 37.5 |
| | now | **16.4 ms** | 11.6 | 16.2 | **32.4** | 9.5 |
| 2,000 players, all moving, view distance 5 (24 viewers each; 3 interleaved runs of 60 ticks) | baseline | 224.5 ms | 193 | 218 | 319.5 | 190 |
| | now | 141.6 ms | 117 | 135 | 234.0 | 115 |

Targets given for this work, and where they stand:

| Target | Result |
|---|---|
| 500 players all moving: avg <= 20 ms, p99 <= 40 ms | **not met**: 39.4 / 64.6 ms (halved from 81 / 122) |
| 500 players, 20% moving | met: 16.4 ms avg, p99 32.4 ms |
| 2,000 players "sparse", avg <= 50 ms | **not met**: 141.6 ms (the game phase is 113 ms of it; baseline 224.5 ms) |
| crowded worlds "as good as you can get" | not measured separately; the fan-out (below) grows with viewers per player |
| no outliers above 100 ms from the tick itself | met over 520 ticks (worst tick 92 ms, flat trend), **after** the queue fix below; the baseline drifted from 47 to 96 ms in the same time |

Phase breakdown, 500 players all moving (`mc.server_tick_log`, averages of the A/B runs):

| Phase | baseline | now |
|---|---|---|
| process (input to the game's queue) | 7.2 | 3.5 |
| game tick (movement, visibility, input, chat, keep-alive) | 52.1 | 27.8 |
| block actions and broadcast | 4.3 | 0.2 |
| chunk streaming | 10.5 | 4.7 |
| drain (`mc.play_out` -> `net.outbox`) | 6.5 | 3.6 |

## How it was measured

`tests/bench/tick/run.sh PLAYERS SIDE FRACTION [TICKS] [LABEL]` runs the tick with per-tick **wall** time and per-tick **on-CPU** time (`/proc/self/schedstat` read from SQL: it grows less
than wall time when other jobs load the machine).  `ab.sh` alternates two databases that differ only in the SQL under test (`createdb -T`), which cancels most drift.  `TOPN=n` prints the most
expensive statements from `pg_stat_statements` (with `track = all` for nested statements and `track_planning = on`), `TREND=1` the tick time per 100 ticks and the queue sizes, `explain.sh` the
`auto_explain` plans of three ticks.  The warm-up the benchmark needs: `mc.generate_flat_area` and `mc.chunk_packet` over the chunks the walk reaches (a never-visited chunk costs 5 ms on the tick).

Baseline profile (500 moving, nested statements per tick): `mc.apply_player_moves` 27.9 ms (its broadcast statement 13.1, decode 4.4, "last position per connection" 1.8 plus an `ANALYZE` of a temp table
1.2), `mc.refresh_visibility` 11.8, `net.stream_chunks` 10.9, drain 3.9 + 2.4 + 3.4, **planning 12.3 ms** (statements planned again every tick, see below).

## What changed, with the evidence

1. **Fused input path** (`sql/430`, `net.process_fast`, `mc.tick_core`).  A move packet used to be copied through five tables (`net.inbox`, `net.batch`, `net.play_inbox`, `mc.play_in`,
   `mc.play_in_work`); now one statement classifies the inbox and writes the game's packets straight into `mc.play_in_work`, the rest to `net.batch`.  `net.conn.last_activity` (nothing reads it) is refreshed once a second per
   connection instead of every tick.  `net.process()` is unchanged (its tests read `net.play_inbox`).  process 7.2 -> 3.5 ms.
2. **No plan invalidation on the hot path** (`sql/432`, `sql/431`).  PL/pgSQL caches plans, but `TRUNCATE`, the implicit truncate of `ON COMMIT DELETE ROWS` temp tables and `ANALYZE` of a temp table invalidate
   them: 12-14 ms of planning per tick.  Rewriting the functions to keep their per-tick sets in PL/pgSQL **arrays** (no scratch tables at all) halved the planning total (13.8 -> 6.1 ms measured on a clone; p10 tick 51 -> 41 ms).
3. **Movement fast path** (`sql/431`).  When no connection sent two position packets and no packet is malformed (the two violation rules, which need the ordered scan), movement is decoded with `DISTINCT ON`
   instead of window functions, and applying the move and broadcasting it are one statement that reads and updates `mc.player` once (it used to read it three times and update it twice).  The original
   function is kept verbatim as `mc.apply_player_moves_general` and used for every other input.  `tests/sql/431_tick_perf_moves.sql` runs both on 10 flavours of random state (jumps, teleport confirmations,
   players awaiting a teleport, positions changed by other code, NaN coordinates, two position packets, malformed lengths, moves over the 16-bit delta) and compares every player row, queued byte, kick and counter;
   a mutation test (breaking the on-ground handling) is detected.  Function call counters show which path ran.
4. **Visibility refresh** (`sql/432`): dirty players looked up through the entity index (`= any(array)`), pairs to delete found through the primary key and the target index instead of scanning all 9,700 pairs,
   an immediate return when nobody changed chunk.  `remove_entities` lists ids in ascending order (it was unspecified; the original kept as `mc.refresh_visibility_general` with that one change for the comparison).
5. **Chunk streaming** (`sql/432`): flat-world generation only for chunks that do not exist (it was called, and found the chunk, 140 times per tick), and a chunk whose cached packet is current is read by one join
   instead of `mc.chunk_packet()` per chunk (a row lock, three lookups, 28 us each).  "Current" is exactly the condition under which `mc.ensure_chunk_current()` does nothing; the equivalence test covers chunks that are
   edited, dirty without a version bump, and missing (a mutation dropping the dirty check is detected).  chunks 10.5 -> 4.7 ms.
6. **Idle block handling** (`sql/432`): `mc.apply_block_actions` and `mc.broadcast_block_events` return at once when there is nothing to do (they planned and ran six statements every tick).  2-4 ms -> 0.2 ms.
7. **Reference ids as plan-time constants** (`sql/433`): `mc.pid`, `mc.sid` and `mc.entity_type_id` are `IMMUTABLE` PL/pgSQL, so the planner folds the number into the cached plan (44 lookups per tick, 2.6 ms; and one of them,
   inside `mc.pkt_add_player_entity`, stopped `proto.frame` from being inlined, which cost a freshly planned call per new visible pair).  **Consequence:** a session keeps the ids it planned with; after reloading
   `ref.packet` / `ref.registry`, restart the gateway.  A fresh database is unaffected.
8. **Drain** (`sql/430`): `mc.play_out` is moved into `net.outbox` row for row in one hop; `net.drain_outbox()` concatenates per connection when the gateway reads.  (Aggregating in the tick as well cost 24 ms instead of 9 ms
   at 2,000 players because the same bytes were concatenated twice; whole cycle, tick drain plus gateway read: 28.4 -> 15.1 ms.)  Compressing connections keep the `net.reframe` path, now fed through an array.
9. **Queue housekeeping** (`sql/435`) -- see the next section.

## Queues that are emptied with DELETE (found while measuring, and present in the baseline)

Every queue (`mc.play_out`, `mc.play_in_work`, `net.inbox`, `net.outbox`, `net.batch`) is filled and emptied each tick.  A deleted row stays until a vacuum removes it, and every later scan walks it.  With the default autovacuum
(a look every minute, 20% dead rows) a 520-tick run (26 s) gave

    tick avg per 100 ticks:  46.5   47.5   66.0   72.2   95.6 ms      queue pages at the end: play_out 15,478 (121 MB, no row in it), net.inbox 4,339, mc.play_in_work 4,316

The short benchmarks never showed it because `ibench.setup` truncates the queues.  A gateway that runs for hours would.  Two tempting fixes were measured:

* **Aggressive autovacuum on all queues**: the bloat disappears (play_out 462 pages) but a vacuum of a table that happens to be empty stores `reltuples = 0`, and the planner then believes the table has ONE row for as long as the
  statistic stays.  Seen in plans: nested loops that re-run a sort 500 times, a decode statement taking 17 ms, a movement statement 76 ms for 500 packets.  The run was also noisy (57-84 ms per 100 ticks).
* **TRUNCATE every tick** (what the baseline did for the small queues): no bloat and sane statistics, but every truncate invalidates the plans of every statement that mentions the table (`mc.play_out` has about twenty): +1.5 ms of planning.

What `sql/435` and `mc.server_tick()` do: `mc.play_in_work`, `net.batch` and `mc.play_out` (only the tick touches them) have autovacuum **off** and are truncated once a second (every 20th tick, when they are empty; the invalidation cost is
about 0.5 ms per tick on average).  `net.inbox`, `net.outbox`, `mc.play_in` (shared with the gateway, so the tick cannot truncate them safely) keep a hot autovacuum (500 dead rows, no throttling); their statistics may read
"empty", but the statements that read them do not depend on the row count.  Required in `postgresql.conf`: `autovacuum_naptime = 1s`.  Result over 520 ticks:

    tick avg per 100 ticks:  53.0   45.7   53.3   53.2   47.2 ms      queue pages at the end: play_out 0, net.inbox 209, mc.play_in_work 9      worst tick 92 ms, p99 84.5 ms

## What did not work

| Tried | Measured | Verdict |
|---|---|---|
| ordinary UNLOGGED scratch tables emptied with DELETE (instead of temp tables) | `mc.vis_want` 450 pages for 278 live rows; the chunk phase swung between 6 and 38 ms from run to run | dropped: arrays |
| temp tables `ON COMMIT PRESERVE ROWS` + DELETE | 122 pages for 500 rows after 100 ticks; a temp table is never vacuumed, so it grows for the life of the session | dropped: arrays |
| `plan_cache_mode = force_generic_plan` | planning unchanged (13.6 ms): the plans are invalidated every tick anyway | reverted |
| `STORAGE EXTERNAL` on the queue `bytea` columns (no pglz of 7-20 KB chunk packets) | -2.3 ms on the drain statement in one run, but with DELETE the dead TOAST rows are 20x bigger and bloat faster | dropped |
| packet fields packed into one `int8send` value and `[length][id]` as one two-byte value | game phase 36.7 ms against 33.2 ms for the original build (4 interleaved runs each): slower | dropped |
| visible pairs read in primary-key order (index scan) so the sort sees sorted input, grouped by `viewer_eid` | aggregate alone 9.4 -> 6.2 ms in isolation, but in the real statement the planner builds the hash on the 9,700-row side and nothing changes (p10 identical, average slightly worse) | dropped |

## Planner traps worth knowing (each cost an hour)

* A table whose last vacuum found it empty is planned as one row (above).  `TRUNCATE` resets the statistic to "unknown", which falls back to the real size.
* Filtering on `conn_id % n = k` makes the planner estimate about 2 rows (default equality selectivity); everything downstream becomes nested loops, quadratic in the shard's size.  Select the connections into an
  array first and filter with `= any(my)`.
* A SQL function whose argument contains a subquery is not inlined when the function uses that argument twice (`proto.frame` uses its body twice), and a function that is not inlined is planned again on **every call**
  (86 us for the frame builder).
* `get_byte()` on a large value detoasts the whole value on every call (docs/COMPRESSION.md).

## Parallelism

The database comparison found that four concurrent writers scaled between 0.5x and 1.5x on every engine and did not find out why.  Findings (`tests/bench/tick/parallel/`, PostgreSQL 16, fsync off, `synchronous_commit` off):

* **The machine is not four free cores.**  It is 4 vCPUs shared with other jobs (the other workers' database processes were using about 1.6 cores while these ran).  A pure-CPU query that touches no table scaled x2.05 / x2.6 /
  x2.66 / x3.13 at 2 / 3 / 4 / 6 clients, and the same measurement taken a minute apart varied between x2.1 and x3.2.  (A Python-only loop on an idle machine scaled x3.93, so the cores are real; they are just not free.)
  A comparison of workloads is therefore only meaningful against a pure-CPU reference measured right next to it; `run.sh` does that.
* **Writers, 500 wide rows updated per statement, 4 clients against 1, divided by the pure-CPU reference ("efficiency")**: one logged table per client 0.71-0.80; one unlogged table per client 0.50-1.19; one shared logged table (disjoint row blocks) 0.61-0.82;
  one shared unlogged table 0.93-1.05.  So logged tables cost roughly 20% of the scaling; sharing a table between writers on disjoint rows costs nothing measurable.
* **Where the writers wait** (`waits.sh`, 4 clients on separate logged tables, 228 samples): 199 running on a CPU, 24 `Timeout:SpinDelay` (spinlock contention, plausibly WAL insertion), 2 `LWLock:XactSLRU`, 2 `Client:ClientRead`,
  1 `LWLock:LockManager`.  No lock or I/O wait is significant; WAL was 56 MB/s at 1,100 statements/s.  The poor scaling reported earlier is mostly the shared machine plus about 20% for WAL, not a database defect, and fsync, `wal_level` and
  commit settings were not the cause (fsync was already off).  Not tried: `wal_level = minimal`, `commit_delay`, `wal_buffers` above 4 MB (these need a restart of the shared dev cluster).
* **Region-sharded movement** (`sql/434`, opt-in, not called by the server): `mc.apply_player_moves_shard(tick, k, n)` handles the connections with `conn_id % n = k`; n workers run concurrently, touch disjoint rows and append to the shared
  queue.  One iteration = generate the shard's packets + move + discard its output; the time of one tick is the time of one iteration.  Measured against the pure-CPU reference:

  | players | workers | ms per tick | speed-up | pure-CPU reference |
  |---|---|---|---|---|
  | 500 | 1 / 2 / 4 | 22-28 / 19-25 / 27-29 | 1.00 / 1.15-1.18 / 0.81-1.01 | 1 / 1.6-2.05 / 2.3-3.2 |
  | 2,000 (view distance 10: about 78 viewers each) | 1 / 2 / 4 | 230-249 / 131-136 / 91-108 | 1.00 / 1.75-1.89 / 2.3-2.6 | 1 / 2.05-2.55 / 3.5-4.7 |

  **Verdict: viable, but only for large worlds and not enough on its own.**  At 500 players it does not pay: every shard still pays the fixed costs of the call (planning, scans of the shared `mc.player` and `mc.visible`, the sort of its
  own fan-out) and appends to one queue.  At 2,000 players four workers give 2.3-2.6x (about 0.5-0.65 of what pure CPU parallelism gives right now), but 4 workers still need 91-108 ms for the movement alone at that density, so a 50 ms tick at 2,000
  moving players is out of reach on this machine with this design.  (The harness's 2,000-player case is the denser one, view distance 10 and about 78 viewers per player, so its 230-249 ms for a single worker is not comparable with the 141.6 ms tick of the view-distance-5 case above.)  What a real sharding needs beyond the prototype: a coordinator that gives every worker its connections (by region, not by id), runs the general path for the
  connections the sharded call rejects, and runs visibility and chunk streaming (still single-threaded: 6 and 5 ms at 500 players).  Do not enable it by default.
* The prototype's first measurement showed a 5x single-worker slowdown and an impossible 4.7-5.7x speed-up: the `conn_id % n = k` estimate trap above.  Fixed before the numbers in the table were taken.

## Noise, and how far to trust the numbers

* The machine is shared (load average 2.7-4.2 during the final runs); wall and even on-CPU time inflate when other jobs run (cache and memory bandwidth).  The same code measured in two sessions differed by up to 15%; hence interleaved A/B runs,
  medians, and p10 as the least contended statistic.  Treat differences under about 5% as noise (two identical databases differed by that much).
* Single runs of the 2,000-player case (3 runs of 60 ticks) and the parallel experiments (3 rounds of 4-6 s) have wide ranges; they are in the output of `ab.sh` / `shard_run.sh` and shown above only as ranges.
* The synthetic walk makes players dither across chunk borders: about 150 chunk frames (1.1 MB) per tick.  That is a worst case for the chunk and drain phases and a plausible one for a crowd that runs.
* The e2e comparison with vanilla was not rerun; the byte-level guards are the replay tests (410, 420) and the new equivalence tests, all passing.

## Relation-file churn (follow-up: what the tick still created and deleted per tick, and a slow tick found on the way)

The tuning worker reported about 40 relation files created and deleted per tick and 17 `Storage CREATE` WAL records, and a RAM disk that made its 500-player trial 30% faster (docs/TUNING.md, cause 8).  The question was whether the tick can stop
creating files at all.  **Counting first** (`tests/bench/tick/churn.sh`: `strace -f -y -e openat,unlink,unlinkat,ftruncate` on the backend that runs 100 ticks after 20 of warm-up, plus the `Storage` records of the WAL from `pg_waldump` and `pg_stat_io`),
500 players over 100 x 100 chunks, the tuning trial's bots (25% moving, keep-alive and teleport answers; `WORKLOAD=tune`), per tick:

| Code | files created | files unlinked | `ftruncate` (of temp tables) | WAL `Storage CREATE` | temp-relation extends |
|---|---|---|---|---|---|
| before the first tick work (`dbcraft_base`, the code the tuning trial ran) | **37.0** | 20.1 | 18.1 (14.1) | **17.0** | 38.9 |
| main as merged into this branch (the first tick work already in) | 1.0 | 0.6 | 1.7 (1.7) | 0.45 | 0.9 |
| after this change | **0.7** | 0.4 | **0** | 0.30 | **0** |

So the tuning worker measured the code from before the first tick work: its 37 files and 17 records per tick are exactly what is in the first row, and **most of the churn was already gone** when that work was merged (the per-tick sets became arrays, so the temp tables went,
and the queues are truncated once a second instead of every tick).  What was left, and what this change did about it:

| Source (in the merged code) | Cost per tick | Change |
|---|---|---|
| `mc.deliver_ready_chunks`: temp table `_rdy ON COMMIT DELETE ROWS` (with its TOAST table), emptied at every commit that touched it | 1.7 `ftruncate`, plan invalidation | `sql/430_chunk_queue.sql`: five PL/pgSQL arrays |
| `mc.broadcast_block_events`, on every tick with a block change or an acknowledgement: temp tables `_bchg`, `_bchunk`, `TRUNCATE` of `mc.pending_ack` and `mc.block_actor` | **about 10 files per tick** (with 3 block edits and 5 acknowledgements per tick: 10.9 files, 5.7 `ftruncate`, 4.45 `Storage CREATE`) | `sql/432`: arrays; the two small queues are consumed with `DELETE ... RETURNING` / `DELETE` (autovacuum keeps them clean) |
| the once-a-second `TRUNCATE` of `mc.play_in_work`, `net.batch`, `mc.play_out` (6 relation files and their init forks: 12 files, every 20th tick) | 0.6 files per tick on average, all in one tick per second | skipped for a queue that was not written since its last truncate (its file has zero length): **an idle server creates no relation file at all** (tested).  **Kept otherwise**, see below |
| `mc.ensure_chunk_current`: `SELECT ... FOR UPDATE` on the chunk row at every call (16% of the WAL in the tuning measurements) | one locked tuple in the WAL per call | `sql/220`: read without the lock; lock and re-read only when the chunk is dirty.  (`mc.chunk_packet` had already stopped calling it for current chunks, so the benchmark tick does not call it; `mc.generate_flat` and the chunk-build path do) |

With block activity (`WORKLOAD=blocks`: the same bots, three block changes and five pending acknowledgements per tick, as if a few players were building): files created per tick 37.0 before the first tick work, **10.9** in the merged main, **0.9** now (no `ftruncate`, 0.30 `Storage CREATE`).
What is left, 0.7-0.9 files per tick, is the once-a-second truncate of the three tick-owned queues and the free-space-map files that appear after it.

**Alternatives measured for that last part, and why it stays.**

* *DELETE instead of TRUNCATE, no cleanup* (the three queues only DELETEd): the 100-tick average of the standard benchmark went from 38.0 to 43.5 ms (4 interleaved runs each); the queues are scanned with their dead rows and the tick grows with the age of the table (the finding of `sql/435`, repeated: this is why they are truncated at all).
  The once-a-second truncate burst costs in the order of 4 ms in the one tick of 20 that carries it (`tests/bench/tick/by_second.sh`, only 4 samples per position: noisy) and the truncates themselves about 0.6 ms on disk (the tuning worker's `truncate_cost.sh`: eight unlogged truncates and a commit 1.7 ms), so keeping it costs about 0.2-0.3 ms per tick on average.
* *DELETE and let autovacuum clean the tick-owned queues*: this is the configuration of `sql/435` that produced `reltuples = 0` and one-row estimates (nested loops re-running a sort 500 times); not retried.  A VACUUM cannot run inside the tick.
* *A rotating set of two or three queue tables*: the queues are written by name by 84 statements in 18 files (`insert into mc.play_out`), so rotating them means a view or dynamic SQL in every writer and a set of plans per table; and it removes no file creation (every table is truncated once per round), it only moves it.  Not built.
* *Permanent UNLOGGED work tables with DELETE instead of temp tables*: a DELETEd table keeps its dead rows, a temp table is never vacuumed (a 278-row scratch table measured 450 pages), TRUNCATE makes files.  Arrays are the only option with no storage at all, and that is what the per-tick sets use.
* *Session-persistent temp tables without ON COMMIT DELETE ROWS*: bloat without bound in a long session (nothing vacuums a temp table), and `ANALYZE` and DELETE of them still invalidate plans.

**A slow tick that was not file churn: the keep-alive round.**  The tuning trial's bots answer the server's keep-alive 300 ticks after the last one, all within a tick or two (`WORKLOAD=tune`).  Tick 301 took **191-362 ms** in all seven runs (`process` phase 163-335 ms, CPU-bound, not I/O): the 500 answers go to the game *and* to
`net.batch`, and `net.process_fast` handled each batch row with `net.handle` (a connection lookup, a packet-name lookup, a VarInt reader that is re-planned at every call, `net.h_play`: 0.3 ms per packet).  Now the answers that are well-formed and the only protocol-level packets of their live play connection
are applied by one UPDATE (`keepalive_id`, `latency_ms`, `teleport_ok`: the only columns `net.h_play` touches for them, whatever the order) and removed from the batch; a connection with anything else in the batch, a short keep-alive, or a multi-byte teleport id
keeps the ordered per-packet path.  The check is `exists (select 1 from net.batch)` after the main statement: free in a tick without protocol-level packets.  (A first version that classified the connections inside the main statement cost 0.8 ms in every tick and was dropped; a second, with a pre-check of the inbox, 0.4 ms.)
Tick 301 is now below the third slowest tick of its run (41-51 ms; 38 ms in the one run where it shows), and the slowest tick of a 340-tick run went from 245-343 ms to 55-81 ms (below).  The `mc.sid()` suspicion in the tuning document (cause 7) is the same thing seen from the side: `mc.sid` is `IMMUTABLE` PL/pgSQL since `sql/433`
and the planner folds it into the plan wherever it is called with a constant (every call on the tick's path is); the per-row calls were in `net.process()` (`sql/420`), which `mc.server_tick` no longer uses, and what cost the time was the per-packet handler.

**Equivalence and tests** (`tests/sql/437_tick_churn.sql`, 115 checks, all passing; the whole suite is 1,207 checks plus the override and clean-migration checks, which also assert that the functions of the tick create no temp table).  The previous body of every rewritten function is kept in `sql/437_tick_churn.sql`
(`mc.deliver_ready_chunks_general`, `mc.broadcast_block_events_general`, `net.process_fast_general`); random states are built, the queues snapshotted, the old function runs, the queues are restored, the new one runs, and the bytes in every connection's queue, the rows left in the queues, the connection rows and the
return values are compared.  Chunk delivery: inline and async mode, caps 1, 3, 8 and 64, ties in the distance, gone, closing and not-yet-playing connections.  Block events: several edits of one position (some net zero), edits by the viewer, whole-section fills (a chunk re-send), acknowledgements only.
The inbox: well-formed and malformed keep-alive answers, matching, wrong, multi-byte and missing teleport ids, moves, pongs, unknown packets, on connections in `play`, `configuration` and closing (connection rows and disconnect frames compared).  Mutations (a wrong tie-break, a missing `distinct`, `min` for `max`, an actor check without the connection, teleport confirmations dropped,
the keep-alive never cleared, a connection taken in bulk when *any* instead of *all* of its packets are answers, a too short keep-alive accepted) are each caught.  One difference is deliberate: the chunk packets of several changed chunks that `mc.broadcast_block_events` sends to one connection used to follow the order of a `SELECT DISTINCT` (hash order: the planner's choice); they now follow the order the changes
were recorded, and the test compares them as a set (everything else, including their position among the other frames, exactly).  `tests/sql/437` also checks that a housekeeping tick on an idle server replaces no queue file and that one after writes does, and that `mc.ensure_chunk_current` leaves a current chunk unlocked (the lock would stamp a new `xmax`).

**Timings** (interleaved A/B: merged main `m0` against this change `m1`, `ab.sh` / `tune_ab.sh`; the machine was shared with the other workers, load average 3-8 during these runs, so the absolute numbers are 10-25% worse than the quiet-machine table at the top; medians of the runs.  The 20% and 2,000-player rows were measured with the previous variant of the keep-alive check, +0.4 ms in every tick; the final one costs nothing there):

| Workload (500 players, 100 x 100 chunks, view distance 10 unless noted) | m0 average | m1 average | m0 p99 | m1 p99 | m0 slowest tick | m1 slowest tick |
|---|---|---|---|---|---|---|
| standard: all moving (8 runs of 100 ticks) | 48.9 ms | 48.0 | 99 | 90 | | |
| standard: 20% moving (6 runs) | 17.6 | 16.6 | 35.0 | 38.4 | | |
| standard: 2,000 players, view distance 5 (3 runs of 60 ticks) | 167.6 | 152.1 | 233 | 239 | | |
| tuning bots, keep-alive round included (3 runs of 340 ticks) | 23.5 / 24.4 / 21.3 | 23.2 / 19.6 / 19.6 | 53.7 / 46.7 / 52.1 | 50.1 / 39.6 / 38.9 | **343 / 271 / 245 ms** | **81 / 58 / 55 ms** |
| tuning bots + block edits and acknowledgements every tick (3 runs of 340 ticks, disk) | 27.9 / 26.3 / 24.4 | 22.8 / 22.4 / 19.5 | 60.5 / 72.0 / 52.6 | 42.6 / 52.9 / 43.6 | 313 / 143 / 149 ms | 56 / 62 / 55 ms |

On the standard workloads (no block changes, no keep-alive round) the change is a wash within the noise, as it should be: they had no churn left to remove.  The gains are where the churn was: **a tick with block activity** (median average -15%, p99 -28%) and **the keep-alive round**
(slowest tick 245-343 -> 55-81 ms: it is no longer the slowest tick of the run).

**RAM disk, for reference** (the same databases copied to a cluster whose data directory is on tmpfs, port 54412, same settings, interleaved with the disk runs; `ab_ports.sh`, `tune_ab.sh`; average tick):

| Code | workload | disk | RAM | difference |
|---|---|---|---|---|
| before the first tick work (`dbcraft_base`) | standard, all moving (4 runs) | 80.0 ms | 72.1 | -10% |
| | tuning bots (3 runs) | 51.7 / 49.7 / 49.2 | 57.1 / 45.7 / 43.3 | median 49.7 -> 45.7 (-8%) |
| merged main | standard, all moving (4 runs) | 40.5 | 39.9 | -1.5%, inside the noise |
| merged main | tuning bots + blocks (3 runs) | 27.9 / 26.3 / 24.4 | 24.5 / 33.4 / 23.0 | no consistent difference |
| this change | standard, all moving (4 runs) | 48.7 | 46.5 | -4.5%, inside the noise (43.6-49.9) |
| this change | tuning bots (3 runs) | 23.9 / 24.4 / 20.8 | 30.6 / 26.1 / 20.5 | none |
| this change | tuning bots + blocks (3 runs) | 22.8 / 22.4 / 19.5 | 21.3 / 23.5 / 20.5 | none |

On this machine the file system costs the old code 8-10%, not the 30% the tuning worker measured on its trial (another volume and another load: that is not a contradiction), and after the change **there is no measurable difference between the disk and a RAM disk** at 500 players: the file system is no longer
on the critical path of the tick, so a RAM disk needs no recommendation.  The objective measure is the `strace` count above: 37 -> 0.7 files per tick (0.9 with block activity, where it was 10.9).

**What is not done.**

* The fallback `mc.apply_player_moves_general` (taken when a connection sends two position packets between two `client_tick_end` or a malformed one, that is a player who violates the movement rules) still uses its two temp tables and an `ANALYZE`; it is kept verbatim as the reference for the equivalence tests.
  A tick in which a player violates the rules therefore creates a few files and replans.  `net.process()` (used by tests), the `*_general` originals and the opt-in batched pipeline (`sql/38x`, another worker's) are untouched.
* The remaining once-a-second truncate is documented above: 0.7 files per tick on average in ticks that have traffic.
* The e2e comparison with vanilla (`tests/e2e`) was not run.

## What remains (in the order it would pay)

1. **Fan-out of movement packets**: 9,700 deliveries per tick (500 movers x 19.5 viewers) cost about 9 ms (hash join, a 9,700-row sort, aggregate, insert) and building the 500 packets about 4 ms.  Viewers in the same chunk see the same targets: grouping them
   would divide the work in crowded areas (not in the sparse benchmark).
2. **`mc.player` is 190 bytes wide and updated for every mover every tick** (2 ms for 500 rows, WAL included, and the table bloats to 150 pages for 500 rows between vacuums).  A narrow `mc.player_pos` table for the hot columns would cut both.
3. **Visibility refresh** (5-6 ms at 500 players with about 8 players crossing a chunk border per tick) and **chunk streaming** (4.7 ms) are the next largest single-threaded phases.
4. **Configuration**: the dev cluster has `shared_buffers` = 128 MB and the working set does not fit; backends wrote about 3 million buffers themselves and one drain statement stalled for 240 ms.  `shared_buffers` of a few GB, a more aggressive
   background writer and `autovacuum_naptime = 1s` belong in the production profile (the tuning worker's area).
5. **Remaining planning**: about 6 ms per tick is still spent planning (the largest items: non-inlined frame builders called from helpers whose arguments contain subqueries, and the big movement statement, 0.5-1.8 ms each tick).
6. **Gateway batching**: a real gateway COPYing frames and reading `net.outbox` in one call each moves the per-tick fixed costs out of the tick.

## Files

| File | Contents |
|---|---|
| `sql/430_tick_perf.sql` | `net.process_fast`, `mc.tick_core` / `mc.tick`, `mc.server_tick` (fused input, drain, housekeeping truncates) |
| `sql/431_tick_perf_moves.sql` | `mc.apply_player_moves` fast path; `mc.apply_player_moves_general` is the verbatim original |
| `sql/432_tick_perf_world.sql` | `mc.refresh_visibility`, `net.stream_chunks`, idle block handling; the verbatim originals as `*_general` for the tests |
| `sql/433_tick_perf_ids.sql` | `mc.pid` / `mc.sid` / `mc.entity_type_id` as plan-time constants |
| `sql/434_tick_perf_shard.sql` | opt-in sharded movement prototype (not used by the server) |
| `sql/435_tick_perf_queues.sql` | autovacuum settings of the queue tables |
| `sql/437_tick_churn.sql` | the previous bodies of `mc.deliver_ready_chunks`, `mc.broadcast_block_events`, `net.process_fast` (as `*_general`) for the equivalence tests; the header lists what replaced what |
| `tests/sql/431_tick_perf_moves.sql`, `432_tick_perf_world.sql`, `437_tick_churn.sql` | fast-versus-original equivalence tests (64 + 115 checks) |
| `tests/bench/tick/` | `run.sh`, `ab.sh`, `explain.sh`, `cpu.sql` (on-CPU time per tick); `churn.sh` (relation files per tick: `strace` + WAL + `pg_stat_io`), `ab_ports.sh` (interleaved runs across clusters: disk against RAM disk), `tune_ab.sh` (the tuning bots, slowest ticks with their phases), `by_second.sh`, `blocks.sql` (block activity); `WORKLOAD=tune` or `blocks` in `run.sh` / `churn.sh` |
| `tests/bench/tick/parallel/` | the pgbench scaling experiments and the sharded movement harness |

Every function above replaces an earlier definition with `create or replace` (the later file wins in `tools/migrate.sh` order); the older definitions in `sql/330`, `340`, `360`, `410`, `420` are untouched.
