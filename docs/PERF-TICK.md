# Tick performance

What was measured, what was changed in `mc.server_tick()`, what did not work, why parallel writers scaled so badly in the database comparison, and where the tick stands.
All changes are SQL in `sql/430`-`sql/435`; every rewritten function is compared with the original on random states by `tests/sql/431_tick_perf_moves.sql` and
`tests/sql/432_tick_perf_world.sql`, and the whole suite (788 checks: the earlier 724 plus 64 new) passes.  The e2e comparison with vanilla (`tests/e2e/run_all.sh`) was **not** run here.

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
| `tests/sql/431_tick_perf_moves.sql`, `432_tick_perf_world.sql` | fast-versus-original equivalence tests (64 checks) |
| `tests/bench/tick/` | `run.sh`, `ab.sh`, `explain.sh`, `cpu.sql` (on-CPU time per tick) |
| `tests/bench/tick/parallel/` | the pgbench scaling experiments and the sharded movement harness |

Every function above replaces an earlier definition with `create or replace` (the later file wins in `tools/migrate.sh` order); the older definitions in `sql/330`, `340`, `360`, `410`, `420` are untouched.
