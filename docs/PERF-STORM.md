# Login storms against the Rust gateway: what the stall really was, and what it costs now (STORM)

**Short answer.**  The login-storm stall was not mainly the login: at the scoreboard's view distance (10) with an explored world **every joiner was sent its whole square of 529 chunks (3.7 MB) inside its own join tick**,
about 80 ms of database time per joiner on top of about 15-20 ms for the join itself.  `docs/PERF-JOIN.md` and `docs/PERF-JOINBUDGET.md` were measured at view distance 2 (49 chunks), where that cost does not show.
Now a joiner gets the nearest 49 chunks in its join burst and the rest over the following ticks, at most one (or, when the first was cheap, two) logins enter play per tick, and the chunk stream takes what is left of a tick budget.
**Measured on a machine that was never quiet (load average 7-25 on 4 cores, other agents' servers and test suites): the worst tick of a 50-join storm fell about 3 times (median of three, interleaved), the p99 of the chat round trip of players who were already online
about 5 times and the worst one about 5 times; for 200 joins the in-database CPU time of the worst tick fell from 4-8 seconds to 0.23-0.25 s.**
**What is NOT shown: a worst tick at or below 55-60 ms.  It is not reached** (CPU time of the worst tick is about 140 ms at 50 joins into 20 players, 230-250 ms at 200 joins into 200 players, see "What is still a loss"), and the **200-join runs with real clients could not be completed
on this machine in the final session** (one overloaded repetition only, no vanilla, see "Measurements").  Do not quote a ratio to vanilla for 200 joins from this file without reading that section.

## What "vanilla's worst tick" was (a correction to docs/SCOREBOARD.md)

The first scoreboard compared dbcraft's **worst single tick** (`max(ms_total)` of its tick log) with vanilla's **worst 100-tick average** (`mspt_worst_window_avg` of `/tick query`, polled every second): 444 ms and 5,726 ms against 44.7 and 53.5 ms.
A 100-tick average hides a stall of several hundred ms (one 500 ms tick adds 5 ms to the average).  `tools/scoreboard/run.py storm2` measures what a player feels instead, on both servers the same way: **players who are already online** (12 idle bots and 8 chat probes, in play and settled) chat once a second per probe
(Vanilla kicks a player for more than about one chat message a second, so eight probes give eight samples a second) and the round trip of every message is logged with its time; the storm (50 or 200 clients connecting within 1 s) is
cut out of that log.  For vanilla the tick figures are the worst 100-tick window's p99 and average (`/tick query` twice a second), for dbcraft the real per-tick maximum and p99 of `mc.server_tick_log`.
**Vanilla is not smooth either**: in the first session (load 3.6-11) a 50-join storm gave a worst window p99 of 200-246 ms (a 155 ms GC pause among them) and chat round trips up to 695-850 ms for the players online; with 200 joins the worst window p99 was 407 and 1,281 ms and the online players waited up to **2.4 and 4.3 s**
for a chat echo.  Its window average (the old scoreboard's number) was 65 ms for 50 and 85-130 ms for 200 joins, not 45 and 54.  Its joiners are slow instead: 45-49 s (50 joins) and 49-57 s (200) until everybody is in with all chunks.

## Where the time went (profile, `tests/bench/join/storm.sql` harness, 100 players online, 20 joiners in one tick, view distance 10, chunks cached)

| Per join (ms of database time, `pg_stat_user_functions`, totals / joins) | before | after |
|---|---|---|
| `net.send_chunks` in all (of it `net.hook_chunks`: reading the cached packets, checking which chunks exist, recording the rest as wanted) | 80.8 (hook_chunks 29.4) | 8.8 for 49 chunks (hook_chunks 7.0) |
| `mc.on_join` + `net.hook_join_info` | 4.8 | 3.1 |
| the rest of the entry (entry burst, tab list, config burst, login checks) | about 4 | about 4 |
| **whole process phase per join** | **98 (1,958 ms for 20 joiners in one tick)** | **about 17 (423 ms for 20)** |
| 100 joiners in one tick | 23.2 s | 2.0 s |

A tick that delivers 600 chunks (the old global cap) costs 13-25 ms in `mc.deliver_ready_chunks` + move to the outbox and 10 ms more in the gateway's drain; the old delivery query ranked every wanted row of every connection every tick.

## What changed (all client-visible bytes per joiner unchanged except where stated)

* **`net.hook_chunks` (sql/430_chunk_queue.sql, edited in place)**: only the nearest `dbcraft.join-chunks-inline` chunks (default **49**, the whole square at view distance 2, so every recorded-vanilla comparison, which runs at view distance 2, is unchanged) are returned for the join burst; the rest of the square is recorded
  in `mc.chunk_wanted` (a plain set-based insert: 1.5 ms against 5 ms through `mc.want_chunks`) and sent by `mc.deliver_ready_chunks`.  0 = the old behaviour.  **Deviation from the old bytes, deliberate:** above view distance 3 the chunk packets arrive in more than one `chunk_batch_start..finished` group (first group 49 chunks), in later ticks, interleaved with whatever else
  is sent in those ticks.  Vanilla's own chunk sender also sends many small batches; the chunk packets and their nearest-first order are identical (`tests/sql/920`: 121 chunks, md5 of every packet in order, with and without the split).
* **`mc.deliver_ready_chunks` (sql/791_join_chunk_budget.sql, edited in place)**: rewritten so its cost depends on the caps, not on the backlog (a storm of 200 leaves 96,000 wanted rows): per connection an index scan (new index `(conn_id, dist, cx, cz)`) with `LIMIT`, a loose index scan for the connections that have rows,
  rows of departed connections dropped, rows outside a moved client's square dropped when its view moved (`mc.chunk_wanted_view`), the cached packet read by a join instead of the plpgsql function.  Both caps (`dbcraft.chunk-batch-max` 64 per connection, `dbcraft.chunk-budget-per-tick` 600 in all) apply in inline mode too (they were async-only).
  **`dbcraft.tick-budget-ms` (40)**: the shared cap shrinks with the time the tick has already used (`net.process_fast` records its start in a transaction-local setting): a tick that spent the budget sends 40% of the cap, a tick without joins all of it; not scaled when no start was recorded (tests, the batched tick), `off` = the cap alone.
  Same frames, same order per connection (`tests/sql/437` and `432` compare it with the previous bodies).
* **Join entry budget (`net.process_fast`, sql/430_tick_perf.sql, edited in place; settings in sql/920_join_stage_budget.sql)**: the packet that makes a connection enter play (`finish_configuration`) is the expensive step.  Once a tick has spent `dbcraft.join-entry-budget-ms` (**10**; `off` = never) in the function, further entries
  are put back into `net.inbox` with their sequence numbers (and everything behind them from the same connection) and run in the next tick, oldest connection first; `dbcraft.join-entry-free` (1) entries per tick always run.  A connection that waited past `dbcraft.join-max-wait-s` is let in regardless, **at most 3 per tick**
  (without that cap a queue whose members all hit the limit together, as on an overloaded machine, was let in as one tick of 2-8 s; found in the last measurements).  The client is waiting for its `login` packet and sends nothing, so nothing is lost; the joiner's bytes are identical to the unbudgeted run (`tests/sql/920`: md5 of six burst streams, entity ids and tab list included).
  The login gate of sql/790 (AIMD on the hello) stays as it was: with the entry budget it settles at one hello per tick.
* **Harness (`tools/scoreboard/`)**: `run.py storm2` (a storm into a server with players online, with the chat probes), `loadgen.py --probes/--probe-interval/rtt log with time`, `dbcraft.sh` kills only its own gateway pid (it used `pkill -f gateway/target/dbcraft-gateway`, which kills every other agent's gateway on a shared machine), `vanilla.sh` takes the jar and the heap from `SCORE_JAR`/`SCORE_HEAP`.

## Measurements

Machine: 4 cores shared with about 8 other agents; **load average 7-25 during every number below** (the first session 3.6-17).  Wall times are inflated by that, CPU times less.  Own PostgreSQL cluster in `/dev/shm`, Rust gateway, view distance 10, flat world pre-generated on both servers, 20 players online (12 bots + 8 probes), storm of N clients in 1 s.

### Real clients, 50 joins (post-restart session, interleaved vanilla / old dbcraft / new dbcraft, 3 repetitions, load 7-18, machine busy 95-100%)

| | vanilla | dbcraft before | dbcraft after |
|---|---|---|---|
| worst tick (dbcraft: max tick; vanilla: worst 100-tick window p99), ms | 1,409 [244-2,269] | 854 [500-2,055] | **265 [148-368]** |
| dbcraft p99 tick / vanilla median of window p99, ms | 301 [136-421] | 772 [486-1,395] | **220 [89-303]** |
| ticks over 100 ms | | 31 [19-31] | 51 [1-58] |
| online players: chat round trip during the storm p50 / p99 / max, ms | 548 / 5,064 / 5,085 | 556 / 2,005 / 2,209 | **208 / 417 / 437** |
| time until all joined with all chunks, s | 60.8 [43.8-68.3] | 20.0 [9.1-22.0] | 16.9 [5.5-22.2] |
| runs in which connections were dropped (gateway read timeout under CPU starvation) | 0 of 3 | 2 of 3 | 1 of 3 |

Ranges are min-max of 3; the spread is as large as the effect for "ticks over 100" and "time until all joined" (the load changed by a factor 2.5 between repetitions).  The sorted p50 of vanilla is a median of few samples (68 to 280 per run).

First session (before the restart; the raw file was lost with `/dev/shm`, numbers copied from the console output; load 3.6-17), 2-3 repetitions: **50 joins**: vanilla worst window p99 223 [200-246], window average 65, chat during p50 27 / p99 462 / max 773, all in 47 s;
dbcraft before: worst tick 340 [206-573], chat p50 156 / p99 474 / max 525, all in 6.5 s; dbcraft with the chunk split and an early version of the budgets: worst tick 82 and 84, no tick over 100, chat p50 108-110 / p99 192-217 / max 199-221, all in 3.5 s.
**200 joins**: vanilla worst window p99 407 and 1,281, chat p50 50 / 178, p99 2,426 / 4,285 (max 4.3 s), all in 49 and 57 s; dbcraft before: worst tick 298-925, chat p50 217-444, p99 657-2,023, all in 19-26 s;
dbcraft with the entry budget (10 ms) and static caps: worst tick 535 and 197, chat p50 184 / 155, p99 969 / 384, all in 26 and 21 s; with the time-scaled cap (floor 15%, an intermediate version): worst tick 132, p99 111, chat p50 93, p99 216, max 249, but all in 37 s (the cap shrank too far; the shipped floor is 40%) and a second repetition hit a 7.6 s stall of the whole machine.
**Final code, 200 joins, real clients: one repetition at load 20-25 (the only one that ran; vanilla did not start in 4 of 4 attempts within its 120 s limit, so there is no vanilla number from this session)**: before: worst tick 13.4 s, 109 of 200 joiners and the 12 online bots lost to the gateway's 30 s read timeout, chat p99 for the online probes above 10 s;
after: worst tick 1.27 s, p99 765 ms, 51 of 200 joiners lost (same cause: the load generator and the server were starved of CPU), chat p50 434 / p99 1,980 / max 2,352 ms.  An improvement of the same direction, but **an overloaded run, not a result**: nobody finished within the 240 s limit on either version.

### Paced in-database storm, CPU time per tick (`tests/bench/joinbudget`, view distance 10, 20% of the online players walking, old and new code interleaved; on-CPU time, so load matters less; the first 8 ticks, which include the harness's own setup, excluded)

| scenario | | worst tick CPU ms | p99 CPU ms | median CPU ms | ticks over 100 ms CPU |
|---|---|---|---|---|---|
| 50 joins into 20 online, 3 reps | before | 276 / 243 / 225 | same (about 100 ticks) | 71 / 76 / 38 | 15 / 16 / 20 |
| | **after** | **142 / 144 / 139** | 116 / 121 / 120 | **26 / 32 / 27** | **2 / 2 / 2** |
| 200 joins into 200 online, 2-3 reps | before | 4,109 / 6,952 / 8,070 | 3,870 / 4,792 / - | 40 / 183 / 77 | 21 / 19 / 15 |
| | **after** (final code) | **229 / 251** | **174 / 168** | 49 / 44 | 51 / 47 of about 1,000 |

The remaining ticks over 100 ms at 200 online are, for the most part, the steady cost of 200 players of which 40 walk (every 20th tick about 100 ms CPU, also after the storm; `mc.apply_player_moves`, another track's) and, during the storm, the tick with the entry plus 240 chunks.
The same harness with the earlier overdue rule (everything past 20 s let in at once) showed ticks of 1.6 and 2.1 s CPU and 14-16 ticks over 100 ms: that is the flood the cap of 3 per tick removed.
**All-in time in this harness: 62 and 72 simulated seconds (after) against 34-40 (before)**.  The harness clock advances by the real duration of every tick, and the ticks averaged 144-168 ms of wall time on this loaded machine for 56-59 ms of CPU, so 430 ticks needed
(200 entries at one per tick, 106,000 chunks at 240-600 per tick) would take about 430 x 55 ms = 24 s on a machine that keeps the 20 Hz tick; **that is an estimate, not a measurement**, and under the load of this session the join of 200 players took longer than before and about as long as vanilla's 49-57 s.

## What did not work or was changed after measuring

* **Spreading only the hello (the existing AIMD login gate)**: the cost sits in the entry, three ticks after the hello, so the controller (which looks at the previous tick) oscillated: ticks alternated between 10 and 200-570 ms with clients arriving in waves.
* **A static global chunk cap of 600 per tick** is 13-25 ms of delivery plus 10 ms of gateway drain: more than the whole tick target.  Scaling it with the time already spent (`dbcraft.tick-budget-ms`) works, but a floor of 15-25% made the 200-join chunk stream take 37 s instead of 22 s; 40% is the compromise.
* **Writing the remaining 480 chunk rows through `mc.want_chunks`** (unnest, `ON CONFLICT DO UPDATE`): 5 ms per join; a plain `INSERT ... SELECT` 1.5 ms.
* **The first overdue rule** (a connection past its maximum wait is never held): under overload everything crosses the limit together; 100+ entries in one tick (2 s CPU).  Now at most 3 per tick.
* **Ranking all wanted rows each tick** (the old `mc.deliver_ready_chunks`) cannot work with the backlog a spread-out join creates: rewritten.
* Not tried: a per-connection chunk cursor instead of 480 rows per joiner (it would remove 1.5 ms per join and the delete of delivered rows); `mc.on_join`'s O(online players) fan-out (2.5 ms per join at 100 online, more at 200); the unattributed 100 ms tick every 20th tick at 200 online (movement bookkeeping).

## What is still a loss or open

* **Worst tick <= 55-60 ms is not reached.**  50 joins into 20 players: CPU 140 ms worst (the tick in which two entries or an entry and the 20th-tick work coincide), 25-30 ms median; 200 into 200: 230-250 ms worst, 45-50 ms median, p99 170 ms.  Vanilla's own figure is not 55 ms either (see the correction above): its worst window p99 was 200-246 ms (50 joins) and 407-1,281 ms (200),
  its online players saw up to 0.7-0.85 s and 2.4-4.3 s.  dbcraft's chat round trip for the online players during the storm is better in the tail (p99 417 against 5,064 ms in the loaded session; 192-217 against 462 in the quieter one) but **worse in the median in the quiet session** (108-208 ms against 27 ms at 50 joins):
  a chat message waits for the next tick (20 Hz) and the tick is 30-60 ms long during a storm.
* **200 joins with the final code and real clients, and the vanilla comparison for them, are not measured on a usable machine** (see above).  The time to all joined with all chunks at 200 joins is expected between 20 and 40 s (not measured).
* Under CPU starvation (load 15-25) the gateway's 30 s read timeout dropped all connections in some repetitions of both the old and the new code (`gateway_failed_*.log`, "dropped: read timeout (no bytes)"); this was seen before this work too (a 50-join baseline run lost its 12 online bots).
* The gate of sql/790 still has its own deadline floor, which can release a queue in a burst.
* `tests/e2e` (fixed ports) was not run.

## Tests

`tests/sql/920_join_stage_budget.sql` (29 checks; the whole suite: 65 files, 2,294 checks, `tools/check_overrides.py`, `tools/check_inlining.sh`, `tools/check_fresh_migration.sh` green): budget off = all six enter in one tick; exhausted budget = the free entry only, the others back in `net.inbox` in order, one more per tick, all six in after nine ticks, and **their join bursts byte for byte the same as without the budget**; two free entries; a connection past its wait is let in, at most 3 overdue per tick; what a held-back connection sent behind its entry packet waits with it;
121 chunks at view distance 4 in the same nearest-first order with `join-chunks-inline` 0 and 49 (first batch 49); the delivery step with a backlog (shared cap round-robin, view moved, connection gone).  `tests/sql/791` and `430` unchanged except that `dbcraft.tick-budget-ms` is set `off` where a fixed cap is counted.

## Raw results

`docs/perf-storm-results.jsonl.txt`: one JSON line per run of the post-restart session (`file` = `fin1`: real clients, 50 joins and one 200 set; `fin2`: the 200-join repetition; `jbp`: the paced in-database runs, including the 200-join runs with the earlier overdue rule), without the per-sample arrays.
The first session's raw file was lost with `/dev/shm` when the container restarted.

## Reproduce

```
tests/e2e/setup.sh                                    # own cluster: DBCRAFT_PGDATA, DBCRAFT_PGPORT (never /tmp for the data)
SCORE_GATEWAY=rust tools/scoreboard/run.py storm2 --n 200 --reps 3 --servers vanilla,dbcraft --tag x      # the real-client storm with chat probes (SCORE_PGDATA, SCORE_PGPORT, SCORE_GW_PORT, SCORE_VANILLA_*, SCORE_OUT, SCORE_HEAP)
JB_PORT=... JB_DB=... python3 tests/bench/joinbudget/run.py --joiners 200 --online 200 --budget 25 --vd 10 --side 30 --walk 0.2     # paced, CPU time per tick
```
