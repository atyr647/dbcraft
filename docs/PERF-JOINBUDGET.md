# Join budget: bounding the worst tick of a login storm (JOIN-BUDGET)

> **Update:** this document was measured at view distance 2.  At view distance 10 the dominant cost was each joiner's 529-chunk square inside its own join tick; see [PERF-STORM.md](PERF-STORM.md) for what changed afterwards (chunk square spread over ticks, join entry budget, time-scaled chunk cap).

**Result.** 200 joins in 1 s into a server with 200 walking players: worst tick **739 ms → 112–204 ms** (median of 2, wall; CPU 701 → 103–198 ms), nobody times out, everybody is in after 7–9 s (vanilla: 63.7 s for 200). 500 joins: worst tick 3.6 s → 0.24–1.0 s. The target of **≤ 100 ms is NOT met** for 200/500 joins with 200 online (see "Remaining risks"); it is met for 50 joins and for 200 into an empty server (116 ms, borderline). Per-join output is byte-identical.

(The 5,726 ms of docs/SCOREBOARD.md was measured with real clients; the simulation here starts from 739 ms because its clients are paced stage by stage. The ratio is what matters: off vs budget is 4–10x on every storm size ≥ 200, measured interleaved.)

## Profile of the stall
A join costs about 28 ms of database time (60 ms with 200 online). `net.process_fast` handles every packet that arrived since the last tick, so N simultaneous logins are one tick of N × 28 ms; while it runs, more packets pile up, so the next tick is bigger still. Vanilla authenticates off the main thread and streams chunks slowly, so its ticks stay at ~50 ms.

## Design
* **sql/790_join_budget.sql, `net.join_gate()`**, called first thing in `net.process_fast`, `net.process`, `mc.ingest_batched` (one commented line each). A login's `hello` (and everything a connection sent after an intent-2/3 handshake while still in handshake state) is moved from `net.inbox` to `net.join_parked` with its sequence number; each tick the packets of the oldest `rate` *logins* go back into `net.inbox` and are processed in the same tick. Status pings (intent 1) are never parked. Everything after the hello flows unchanged, so a joiner receives the same bytes.
* **Rate**: AIMD. Starts at `dbcraft.join-initial-rate` (3, so small bursts are not delayed at all), +1 per tick while the previous tick took ≤ (tick length before the storm + `dbcraft.join-budget-ms`, 25), halved (min 1) otherwise.
* **Deadline floor**: rate ≥ ceil(queued / ticks left until the oldest login is `dbcraft.join-max-wait-s` old), in real wall-clock ms (default 20 s, capped at 25 s). So nobody starves and the wait is bounded; ≥ 1 login per tick always.
* **No time-outs, no keep-alives needed**: a parked client is in the *login* state, where no keep-alive is a legal packet. The wait is bounded below the clients' limits instead: vanilla `MAX_TICKS_BEFORE_LOGIN` = 600 ticks (30 s), Rust gateway `read_timeout_s` = 30 s. The gateway does not close a queued connection (it is only idle). No queue-position indicator.
* **sql/791_join_chunk_budget.sql**: `mc.deliver_ready_chunks` gets a global cap `dbcraft.chunk-budget-per-tick` (600, 0 = unlimited), async chunk generation only: round-robin across connections, each one's nearest chunk first; the rest stays in `mc.chunk_wanted`. In inline mode a join sends its chunks itself, bounded by the login rate.
* **Settings** (all in `mc.server_property`, with defaults): `dbcraft.join-budget-ms` (`off`/`0` = admit everything at once = the old behaviour exactly, also releases anything parked), `join-max-wait-s`, `join-initial-rate`, `chunk-budget-per-tick`.

## Measurements
Simulation `tests/bench/joinbudget` (`run.py`, `curve.sh`, `summarize.py`): simulated ms clock, paced clients with a 30 s timeout, joiners arrive within 1 s, 200 online walkers (side 30), own PostgreSQL cluster. Configs are interleaved, 2 repetitions, machine load 4–6 on 4 cores (wall times are inflated by other workers; CPU is the better number). `bNwM` = budget N ms, max wait M s.

| config | worst tick wall ms (min-max) | worst tick CPU ms | tick p99 ms | ticks >100 ms | all in (s) | queue p50 / max (s) | timed out |
|---|---|---|---|---|---|---|---|
| 200 on 200, off | 739 (717-762) | 701 | 643 | 8.5 | 3.5 | 0.2 / 0.6 | 0 |
| b25w10 | 127 (123-130) | 124 | 118 | 6 | 8.2 | 3.0 / 7.0 | 0 |
| **b25w20 (default)** | 204 (202-206) | 198 | 157 | 8 | 7.1 | 2.7 / 5.9 | 0 |
| b25w28 | 112 (111-114) | 103 | 105 | 3.5 | 8.7 | 3.1 / 7.5 | 0 |
| b10w20 | 129 (128-129) | 122 | 106 | 4 | 10.4 | 4.2 / 9.3 | 0 |
| b60w20 | 220 (189-251) | 205 | 163 | 11.5 | 4.6 | 1.2 / 3.3 | 0 |
| 200 into empty, off | 475 | 437 | 440 | 8.5 | 2.5 | 0.2 / 0.3 | 0 |
| 200 into empty, b25w20 | 116 | 113 | 103 | 2 | 5.7 | 1.8 / 4.4 | 0 |
| 50 on 200, off / b25w20 | 137 / 111 | 95 / 81 | 119 / 97 | 2.5 / 1 | 1.3 / 1.6 | 0.1 / 0.2 | 0 |
| 50 empty, off / b25w20 | 77 / 95 | 68 / 73 | 74 / 79 | 0 / 0.5 | 1.2 / 1.5 | 0.1 / 0.1 | 0 |
| 500 on 200, off | 3626 (3371-3882) | 3551 | 3366 | 7 | 9.8 | 0.5 / 0.6 | 0 |
| 500 on 200, b25w20 | 1027 (247-1806) | 1012 | 181 | 65 | 20.8 | 8.8 / 18.9 | 0 |
| 500 on 200, b25w28 | 336 (243-430) | 235 | 304 | 119.5 | 25.9 | 11.0 / 24.4 | 0 |
| 500 empty, off | 5135 (3324-6945) | 4044 | 3937 | 7 | 10.6 | 0.6 / 0.6 | 0 |
| 500 empty, b25w20 | 185 (176-194) | 137 | 143 | 22 | 18.9 | 6.7 / 17.6 | 0 |

(An earlier 11-config run before the gate's unit became "logins" instead of "packets" gave the same picture: 200-joiner worst tick 157–290 ms.) The maximum wait is the main knob (longer wait = lower worst tick, later all-in); the budget headroom matters little because the deadline floor dominates. All-in is 5–9 s for 200 (vanilla 63.7 s; off 3.5 s).
Vanilla for reference: worst tick 53 ms.

## Tests
* `tests/sql/790_join_budget.sql` (25 checks): budget off = nothing parked and everything answered in tick 1; admission in arrival order with the AIMD sequence 1, 2, 3 and counters; reset after a storm; deadline floor with a simulated clock; status ping never delayed; a parked connection that disconnects is cleaned up; byte-identity: five joiners with and without the budget get the identical join burst (md5 of every frame, entity ids and world clock held equal).
* `tests/sql/791_join_chunk_budget.sql` (14 checks): shared cap 40 → 40/40/40/27 round-robin, nearest first, 0 = unlimited, inline mode unaffected.
* Existing join tests (130, 385/386, 410/420, 430, 460–467) pass unchanged; the gate is covered by `tools/check_fresh_migration.sh` and the override list.

## Remaining risks
* **≤ 100 ms worst tick is not reached** with 200 online (112–204 ms wall, 103–198 ms CPU) and 500 joins (0.24–1.0 s). One join is 28–60 ms and the tick cannot be split inside a join; a lower tick needs a smaller minimum (1 login per tick) *and* a wait longer than the clients' 30 s limit.
* The 500-join default run had one 1.8 s outlier (min 247 ms); I did not find its cause (suspect machine load or a deadline-floor burst); not reproduced.
* Tick cost grows as joiners accumulate at the spawn (a crowd): a separate issue (CROWD).
* Real clients only through the simulation (stage-by-stage replies); not run against the Rust gateway or real clients here. `tests/e2e` was not run.
* Chunk budget applies in async mode only; the batched tick path calls the gate but wasn't benchmarked.
