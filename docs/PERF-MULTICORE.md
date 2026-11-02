# Does a second core pay? Sharded movement, the entity connection, and what it costs

Question (MULTICORE): the earlier verdict (docs/PERF-PARALLEL.md) was measured on a shared, loaded box. Re-measure on a quiet 4-vCPU machine whether using more
than one core pays for dbcraft, and ship the winner as an opt-in setting. Part 1 is that measurement and the entity connection; Part 2 (mob fan-out) is in
docs/PERF-ENTITY.md. Nothing here is on by default.

Machine: Xeon @ 2.1 GHz, 4 vCPUs (1 thread per core, KVM), steal about 1.3 % of CPU time since boot and 0.0 % while measuring, load average 0.4 to 2 around the runs (other
workers' idle JVMs; every table below is a median or mean of at least two rounds and carries 10 to 15 % noise: differences under that are not findings). Scratch cluster on
tmpfs with `docker/postgresql.conf`'s settings (jit off, `synchronous_commit = off`, `fsync = off`). All scripts: `tests/bench/multicore/`, raw output next to them (`results_*.txt`).

## 1a. Raw scaling of tick-like work (pgbench, 1 to 4 clients, `pgb_all.sh`)

Speed-up over one client (mean of 2 rounds of 5 s; the 1-client value is tps):

| workload | 1 client | 2 | 3 | 4 |
|---|---|---|---|---|
| `cpu`: pure CPU, no tables (sqrt over 300k rows) | 34.6 tps | 1.82x | 2.53x | 3.40x |
| `compute`: string_agg packet building, no tables | 917 tps | 2.06x | 3.37x | 4.68x (cache effects: above 4x) |
| `upd_log`: 10k-row full-table UPDATE of a private LOGGED table | 91 | 1.63x | 2.14x | 2.34x |
| `upd_unl`: the same, UNLOGGED | 132 | 1.82x | 2.71x | 3.35x |
| `queue`: build 5k queue rows, concatenate per connection, TRUNCATE (private queue per client) | 77 | 1.89x | 3.28x | 4.20x |
| `tick`: update + queue in one transaction (private tables) | 38.8 | 1.92x | 2.72x | 3.13x |
| `tick_shared`: the same, one hot table shared by all clients (disjoint row blocks) | 41.1 | 1.66x | 2.29x | 2.85x |

Wait events with 4 clients (`waits_run.sh`, sampled every 100 ms): `tick`: 192 of 237 samples on CPU, 24 `LWLock:WALBufMapping`, 15 `Timeout:SpinDelay`, 4 `IO:WALWrite`;
`upd_log`: 198 on CPU, 41 `SpinDelay`. So the ceiling for logged writers is the WAL (about 15 to 20 % of the time in WAL insertion locks and spinlocks), not the heap, not
the CPUs (steal 0, 1 thread per core, no SMT sharing). Pure CPU work scales 3.4 to 4.7x on 4 vCPUs.

**Finding that changed the first, bad result** (`results_scale_round2_bloated.txt`: `upd_log` 19 to 85 tps at one client, 47 to 50 at four = no scaling at all): a statement
that rewrites EVERY row of a table cannot reuse the old versions of its own statement, so at the default-ish fillfactor 60 a third of the new versions spill into other pages,
are not HOT, and the table (and its indexes) bloats to 150 to 250 MB, after which the work is memory bound and does not scale. At fillfactor 40 (room for a complete second copy of every row
in its page) the same workload scales as in the table above. Rule: a hot table that is rewritten (nearly) completely every tick needs `fillfactor <= 40 to 50`. Not tested
here: whether the real `mc.player` table (updated only for moving rows) profits; it is a cheap lever to try.

## 1b. The region-sharded movement prototype (sql/434), 1 to 4 workers (`shard_both.sh`)

One iteration per tick of each worker, the workers run concurrently, ms per tick = one iteration's wall time (2 rounds):

| players | 1 worker | 2 | 3 | 4 | speed-up with 4 |
|---|---|---|---|---|---|
| 500 | 65.0 / 68.2 ms | 28.1 / 31.4 | 18.5 / 19.4 | 16.5 / 16.9 | 3.9x / 4.0x |
| 2,000 | 549 / 542 ms | 350 / 258 | 146 / 144 | 113 / 107 | 4.9x / 5.1x |

(The 2,000-player cases beat the pure-CPU reference 3.2 to 4.1x: the per-worker working set is a quarter of the tables, cache effects. The single-worker iteration of this harness costs
more on this machine than the 22 to 28 ms in docs/PERF-PARALLEL.md; I could not find out why, only the ratios are used.)

So the earlier "does not pay at 500" does not hold on a quiet machine: the sharded step itself runs about 4x faster on 4 vCPUs. What it buys for a WHOLE tick is limited by the
rest of the tick (Amdahl): in the 500-walker run with A alone (section 1c) the tick is 4.2 ms input + 31.9 ms game (movement, visibility, misc input) + 12.0 ms chunk streaming
+ 2.5 ms drain; sql/434 shards only the movement part of "game". Even a perfect 3.9x of the whole game phase would give 51 -> 27.5 ms (1.9x); with movement being only part of it
about 1.4 to 1.5x is the realistic ceiling (an estimate, the sharded step was not integrated into a whole-tick measurement). Cost: N connections that must meet at a barrier every tick
and a shard split of the players. Verdict: **real but narrow; stays opt-in and unadopted**.

## 1c. Split by function: the entity connection

### Design (`sql/550_entity_split.sql`, setting `dbcraft.entity-mode`)

`off` (default: `mc.entity_tick()` is called by nobody, as before), `inline` (the server tick calls `mc.entity_tick(cur)` after the kicks, before the drain: one connection) and
`split`: connection A runs the player tick; connection B runs `call mc.entity_loop()` (`tools/entity_loop.sh`): one `mc.entity_tick` per tick of A, in its own transaction, following
`mc.game_state.game_time` (it sees tick k after A committed it, so it is at best in lockstep, never ahead). A's hook (`mc.entity_step`, sql/430 and sql/389) only applies the pickups B requested.

**Ownership rules** (one writer per table; the other side reads committed state):

| | A (player connection) | B (entity connection) |
|---|---|---|
| writes | `mc.player`, `mc.inventory_slot`, chunks, `net.*`, input queues, block events, its rows of `mc.play_out`, INSERTs `mc.entity_cmd`, DELETEs `mc.entity_pickup_req` | `mc.entity`, `mc.entity_lane`, `mc.entity_floor`, `mc.solid_mask`, the interest relation, `mc.entity_tick_log`, its rows of `mc.play_out`, INSERTs `mc.entity_pickup_req`, DELETEs `mc.entity_cmd` |
| reads | entity rows (pickup grant) | player rows (positions, chunks, game mode) |

* `mc.play_out` is shared by INSERT only; A's drain (`DELETE ... RETURNING`) sees what is committed at that moment, B's later rows wait one tick. The `TRUNCATE mc.play_out` every 20th tick
  would wait for B's open transaction and destroy its committed rows: it is skipped in split mode (test D holds a real second session's uncommitted INSERT: inline mode blocks, split mode does not).
  Consequence: in split mode `mc.play_out` is cleaned by autovacuum (or put it in the gateway's `maintenance_tables`).
* A block change used to UPDATE entity rows from A's transaction (the wake trigger of sql/541): in split mode it files a `wake` command that B applies at the start of its next tick.
* Pickup: B finds item + player in range and files a request, pushing the item's `pickup_at` 20 ticks ahead; A grants it against the item row and inventory AS THEY ARE NOW (vanished item, departed
  player, full inventory: nothing happens), sends the collector's packets, files `discard` / `setcount` for B; B applies it at its next tick (the other viewers' `take_item_entity` and the removal).
  The only deliberate behaviour difference: a failed pickup (full inventory) is retried after 20 ticks, inline mode retries every 4th tick.
* One-tick lag: A and B each decide on the other's last committed state. Entity packets of tick k are committed by B after A's tick k and drained in A's tick k+1: **at least one tick (50 ms) later than
  inline**, plus however far B is behind.
* **If B overruns** it does not queue up: more than `dbcraft.entity-max-lag` (5) ticks behind, `mc.entity_loop` jumps to A's newest tick. Positions are functions of the tick number (lanes, the sweep's
  catch-up step, `ticks` in the first movement packet is computed from tick numbers), so a jump costs smoothness, not correctness; goal, despawn and pickup cadences inside the skipped ticks are late.
* Known limitation: the mask/floor invalidation trigger on `mc.chunk_section` (A's block edits, chunk generation) deletes rows B may be building: a lock wait of at most one B tick, a deadlock (aborted by
  Postgres after `deadlock_timeout`) only if both hit the same chunk at the same moment. Not handled; rare.
* A long B transaction holds back the snapshot horizon: the harder B's tick (see the crowded row) the more dead `mc.player` versions A has to step over.

### Correctness (`tests/sql/550_entity_split.sql`, two real psql sessions in lockstep via `550_split_driver.sh`)

DETERMINISM: the same scenario (6 walking mobs, 2 stacks to pick up, a sleeping stack woken by a block change) run inline and with A and B as separate sessions, B's tick k right after A's tick k,
ends in the same entity states (positions to 1/4096, cells, sleep, data), the same inventories and the same multiset of packets for every viewer, byte for byte (order across two connections differs by
construction). Also: the pickup request/grant/discard protocol step by step, vanished item / departed player / full inventory, wake command vs trigger, the `TRUNCATE` hazard with a real second connection, mode setting.

### Measurements (`split_all.sh`, `split_crowd.sh`; A = the whole server tick with the synthetic walk of `tests/bench/integration/bench.sql`, ms wall per tick, mobs = 2,000 of which about 1,000 awake)

| scenario | A alone (`off`) | `inline` | `split`: A | `split`: B (entity tick) |
|---|---|---|---|---|
| 200 walkers, 2,000 mobs, paced 20 Hz, 160 ticks | 18.6 (p99 35.0) | 62.1 (p99 96.0; the tick no longer fits 50 ms) | **25.3** (p99 52.2) | 47.9 (p99 81.7), 139 of 160 ticks, lag behind A: 0:107 1:14 2:23 3:1 |
| 500 walkers, 2,000 mobs, back to back, 100 ticks | 51.1 (p99 95.8) | 128.3 (p99 251.6) | **60.3** (p99 96.4) | 58.7 (p99 114.5), 78 of 100, lag 0:63 1:9 2:7 |
| 500 crowded in 3x3 chunks, 2,000 mobs around them, 300 ticks | 75.7 (p99 132) | 199.0 (p99 313.6) | 104.8 (p99 212.8) | 139 (p99 412), 173 of 300, lag 0:84 1:31 2:10 3:24 4:25 |

Reading:
* Entity simulation inside A's tick makes A 2.5 to 3.3x slower in these scenarios (200 walkers: 18.6 -> 62.1 ms: more than the 50 ms tick). On its own connection A keeps 25.3 ms (+36 % over A alone: shared
  memory bandwidth and caches, `mc.play_out` growing by DELETE instead of TRUNCATE, the extra row traffic) and the tick fits.
* B is the bottleneck, not A: at 200 walkers B's entity tick (47.9 ms) is just inside the budget (74 % of ticks in lockstep, worst lag 3 ticks = 150 ms of staleness, 139 of 160 ticks run); at
  500 walkers and in the crowd B cannot keep up with a 50 ms tick at all (it skipped 22 and 42 % of the ticks) and the entities lag up to 4 ticks. Splitting moves the entity work off A; it does not make it smaller.
* The 50 ms staleness is invisible for walking mobs (they are already sampled every 3rd tick), visible for item pickups (they take effect one tick later than inline) and for the reaction of mobs to
  blocks. B's own cost is not lower than the entity part inside A's tick (47.9 ms vs 47.5 to 52.8 ms in the two inline runs at 200 walkers): there is no parallelism inside B.
* Not measured: the 200-player soak with the Rust gateway and real clients (no gateway or clients here), the chunk-generation connection C (`call mc.run_generator()`, sql/430_chunk_queue, existing) and the vacuum
  connection D (the gateway's maintenance thread, existing): both are already separate connections and nothing in this work changes them. B as a gateway thread (the `maint.rs` pattern, `call mc.entity_loop(200)` in a loop) was not built; `tools/entity_loop.sh` is the supported driver.

## Verdict

| design | buys | costs | decision |
|---|---|---|---|
| region-sharded movement (sql/434) | its step runs 3.9 to 5x faster on 4 vCPUs; whole tick at most about 1.4 to 1.9x | N connections meeting at a barrier every tick, a shard split, WAL ceiling for logged writers (about 2.3x at 4 logged writers) | real but narrow: stays opt-in, not adopted |
| split by function (A + B) | removes the entity simulation from A's critical path: A 1.9 to 2.5x shorter than inline in the scenarios above; the 50 ms tick holds with 200 walkers + 2,000 mobs | a second connection, 3 small tables, one tick of entity latency, +36 % on A from contention, B itself must fit 50 ms (it does at 200 walkers, not at 500) | **the winner: `dbcraft.entity-mode = split`, opt-in** (default `off`), with the determinism test |
| `inline` | the simplest way to run the entity simulation inside the tick | all of the entity cost lands on A | opt-in, for small worlds |

What would make B fit 50 ms at 500 walkers and in the crowd is Part 2 (less work per tick: docs/PERF-ENTITY.md), not more cores.
