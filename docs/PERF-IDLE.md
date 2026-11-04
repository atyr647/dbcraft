# Idle cost and chat latency at low load

The scoreboard ([SCOREBOARD.md](SCOREBOARD.md), "Where dbcraft loses" items 3 and 4) said an idle dbcraft server cost 1.9 ms per tick and 0.11 cores against vanilla's 0.27 ms
and 0.01 cores, and that a chat message at 50 idle players took 18 ms longer than in vanilla (p50), with a 406 ms p99 at 200 idle players.  This document is what was measured,
what was changed in SQL and in both gateways, what the chat path really looks like, and what is proved identical.  Everything is in `sql/800`-`802`, in-place edits listed in the
header of `sql/800_idle_tick.sql`, the gateways (`gateway/src/gateway.rs`, `sql/optional/dev_gateway.sql`), and the tests `tests/sql/800`-`802` and the gateway's unit tests.

## Result

> **Correction ([PERF-IDLE2.md](PERF-IDLE2.md)):** the "CPU cores" of the `rust / default` rows below are the PostgreSQL processes only; the gateway process (not a child of the postmaster) was left out of the measurement (0.002-0.03 cores, growing with the players).  The `plpython` rows are right.  PERF-IDLE2.md re-measures with the gateway included.

Same machine (4 vCPUs shared with other jobs; load average 0.2 to 4.8 at the start of the runs, see "Noise"), same load generator as the scoreboard (`tools/scoreboard/loadgen.py`: idle bots that send
`client_tick_end` each tick, one chat probe sending a message every second and timing the broadcast back), world pre-generated, view distance 10.  **Before** is the code at the start of
this work (the commit this branch started from, its own cluster, its own gateway binary); **after** is this branch.  The two builds alternate inside every repetition (`tools/scoreboard/idle_matrix.py`), 3 repetitions of 60 s per cell,
medians with [min-max].  Two gateways, because the scoreboard used the PL/Python development gateway with the batched tick and the production path is the Rust gateway with `mc.server_tick()`:

| gateway / tick | players | build | runs | tick mean ms | tick p99 ms | CPU cores | chat p50 ms | chat p99 ms | load before |
|---|---|---|---|---|---|---|---|---|---|
| plpython / batched | 0 | after | 3 | 0.11 [0.10-0.12] | 0.3 [0.3-0.3] | 0.022 [0.021-0.022] | - | - | 1.9 [0.7-2.8] |
| plpython / batched | 0 | before | 3 | 2.34 [2.16-2.37] | 4.2 [3.7-4.3] | 0.150 [0.135-0.170] | - | - | 1.4 [1.1-1.8] |
| plpython / batched | 50 | after | 3 | 3.22 [2.73-3.31] | 5.9 [5.2-7.2] | 0.125 [0.109-0.125] | 4 [4-5] | 16 [15-18] | 1.1 [0.3-1.6] |
| plpython / batched | 50 | before | 3 | 6.43 [6.16-6.65] | 14.5 [12.5-16.1] | 0.252 [0.247-0.262] | 41 [39-42] | 67 [62-77] | 1.0 [0.9-1.3] |
| plpython / batched | 200 | after | 3 | 6.80 [5.31-7.14] | 11.2 [10.1-11.7] | 0.250 [0.194-0.260] | 9 [7-9] | 28 [25-30] | 0.7 [0.2-1.5] |
| plpython / batched | 200 | before | 3 | 18.44 [17.87-18.86] | 39.3 [33.6-39.7] | 0.520 [0.508-0.550] | 54 [53-54] | 83 [83-89] | 0.8 [0.6-1.6] |
| rust / default | 0 | after | 3 | 0.10 [0.10-0.13] | 0.4 [0.3-1.0] | 0.030 [0.023-0.030] | - | - | 1.0 [1.0-4.8] |
| rust / default | 0 | before | 3 | 2.23 [2.20-2.35] | 7.2 [7.0-7.4] | 0.148 [0.138-0.154] | - | - | 1.8 [1.6-3.8] |
| rust / default | 50 | after | 3 | 2.20 [2.17-2.58] | 9.0 [7.8-14.9] | 0.076 [0.074-0.083] | 6 [5-7] | 16 [15-26] | 0.9 [0.5-4.1] |
| rust / default | 50 | before | 3 | 5.14 [5.02-5.21] | 20.6 [16.4-21.2] | 0.213 [0.200-0.224] | 39 [34-40] | 62 [61-72] | 2.1 [1.3-3.9] |
| rust / default | 200 | after | 3 | 3.28 [3.13-3.51] | 15.1 [13.6-17.5] | 0.107 [0.107-0.113] | 10 [9-14] | 41 [24-44] | 2.9 [0.5-2.9] |
| rust / default | 200 | before | 3 | 9.08 [7.49-11.86] | 27.0 [19.8-43.9] | 0.267 [0.255-0.308] | 48 [39-70] | 67 [67-100] | 2.4 [0.8-2.9] |

Vanilla 26.3 on the same machine, same scenarios, run right after the table above, in the same session (2 repetitions of 60 s each, 3 for the empty server; `tools/scoreboard/run.py` with `--servers vanilla`, its own `-Xms2G` JVM, fresh for every run):

| players | tick mean ms (its own `/tick query`) | tick p99 ms | CPU cores | chat p50 ms | chat p99 ms |
|---|---|---|---|---|---|
| 0 | 0.35 [0.32-0.39] | 0.7-1.6 | 0.017-0.019 | - | - |
| 50 | 37.3 [36.0-38.6] | 66-82 | 0.88-0.96 | 11.2 [10.5-11.8] | 56-71 |
| 200 | 56.5 [53.8-59.2] | 91-115 | 1.35-1.41 | 34.7 [33.2-36.1] | 78-116 |


Reading it: **tick** is `ms_total` of `mc.server_tick_log` (the SQL tick; not the gateway loop), **CPU** is every process of the PostgreSQL cluster plus the Rust gateway (the load generator is excluded),
**chat** is the probe's round trip (client write -> gateway -> database -> every socket -> client read).
idle, and 24.7 ms p50 chat at 50 idle players.

**Summary.**  The empty server went from 2.2 ms to 0.10 ms per tick (22 times) and from 0.15 to 0.02-0.03 cores (5-7 times); vanilla, measured the same day, is at 0.35 ms and 0.017-0.019 cores, so the tick is now lower and the CPU slightly higher (0.03 against 0.02 cores: vanilla is still a little cheaper at rest).
With 50 idle players the tick is 2.0-2.3 times shorter and the CPU 2.0-2.8 times lower (PL/Python gateway and batched tick, Rust gateway and default tick); with 200, 2.7-2.8 times shorter and 2.1-2.5 times lower.  **Chat with 50 idle players: p50 39 -> 6 ms (Rust) and 41 -> 4 ms (PL/Python), p99 62 -> 16 and 67 -> 16 ms; with 200: p50 48 -> 10 and 54 -> 9 ms, p99 67 -> 41 and 83 -> 28 ms.**
In this setup that is below vanilla's own 11 ms (50) and 35 ms (200) at p50 and its 56-71 / 78-116 ms at p99 (vanilla's tick with idle players is a busy 37-57 ms here, which is what a chat waits behind there).  The scoreboard's two losses (items 3 and 4) are closed *for this workload*.  What the numbers do not say: chat from real clients (see the lane's limits below), chat during a long tick
(the p99 is bounded by the longest tick), and anything with players moving.

## Where the idle cost was (measured first)

Per process, empty server, Rust gateway, 20 s (`/tmp/idle/cpu.py`-style sampling of `/proc/<pid>/stat`):

| process | cores before | what it did |
|---|---|---|
| the gateway's database connection (the tick) | 0.070 | 20 ticks a second, each 7 statements from the gateway plus the SQL tick: 2.2 ms (about 60 statements, 5 of them planned again every time) |
| two chunk generator connections (`call mc.run_generator(64, 5)`) | 0.036 + 0.036 | each polled `mc.chunk_request` every 5 ms: 200 polls a second, each a procedure call, three statements and two commits |
| the Rust gateway process | 0.007 | epoll loop, one tick a second |
| maintenance (vacuum thread), walwriter | 0.003 | |
| **total** | **0.150** | (the scoreboard measured 0.11 on a quieter machine: the same order) |

So **half of an empty server's CPU was not the tick at all but the two generator connections polling for work that never came**, and a third was the gateway's own statements around the tick.  With
players the picture changes: 50 idle players cost 5.0 ms per tick of which the game's phases that have nothing to do were about 40% (`pg_stat_statements` over 600 ticks, Rust gateway, default tick: moves 1.3 ms for packets that
only say "tick end", the chat phase 0.29 ms with no chat, the misc input phase 0.2 ms, the packet classification 0.83 ms of which 0.4 ms is planning, the drain 0.34 ms, `net.gateway_ctl`
planned again every tick 0.27 ms ...).

## What changed

### SQL (`sql/800_idle_tick.sql`, `sql/801_urgent_chat.sql`, `sql/802_chat_broadcast.sql`)

1. **A quiet tick** (`mc.tick_quiet()`, `mc.tick_quiet_step()`): when nothing is connected and every queue the tick reads is empty, the tick is the clock (`game_time`, `day_time` + 1), the once-a-second queue housekeeping, and one
   `mc.server_tick_log` row.  The predicate is 15 `EXISTS` probes on empty tables plus the entity-mode and hook checks; the whole quiet tick measures 0.10 ms (SQL tick, as logged).  Both entry points use it (`mc.server_tick` and `mc.server_tick_batched`).
   Documented differences from the full tick: no `mc.tick_log` row (that table holds the game's phase timings), and the `mc.server_tick_log` trim runs once a second instead of every tick.
   **Hook for other modules**: `mc.tick_extra_pending()` (default `false`, folded away by the planner) must be redefined by a module that adds per-tick *world* work (work that has to happen with nobody online); a per-player
   duty needs nothing, because a quiet tick has no player.
2. **Phases with nothing to do are skipped with players online** (`mc.tick_core` and `mc.server_tick_batched`): which kinds of input are in the work queue is one scan; `mc.apply_misc_input` and `mc.apply_chat` only run when their packets
   are there; `mc.apply_player_moves`/`mc.moves_batched` only run unless `mc.moves_idle()` proves they would change nothing (no movement-class packet and nobody whose stored position or rotation differs from what the viewers were last told:
   a `/tp` or an SQL update still gets announced); `mc.keepalive_due` returns after one probe when nothing is due.
3. **`client_tick_end` frames are not queued** unless their connection sent two position packets in the tick (`net.process_fast`, `mc.ingest_batched`).  The only reader of `client_tick_end` is the movement rule "two position packets without a client_tick_end between
   them" (`sql/340`); a connection with fewer than two position packets in a tick cannot trigger it.  Every player sends one per tick, so this was 200 rows inserted into and deleted from the work queue per tick at 200 players.
4. **Plan-time constants** for the two id arrays of the inbox classifier (`net.handled_play_ids_c`, `net.known_play_ids_c`; the same trick and the same caveat as `mc.sid`: restart the gateway after reloading `ref.packet`): two table queries per tick before.
5. **The gateway-facing statements are cheap when empty**: `net.drain_outbox()` (probe only; the queues' size check runs once a second when nothing was written), `net.apply_auth_results()` (probe), `net.gateway_ctl()` (PL/pgSQL: the SQL version was planned again on every call, 0.27 ms),
   and the new `net.gateway_pending(after)`: bit 1 = the outbox has bytes or a connection is closing, bit 2 = control rows after `after`; one 20-microsecond probe instead of the drain and the control query.
6. **The chunk generators poll cheaply and back off** (`mc.run_generator`, `sql/430_chunk_queue.sql` in place): the poll is one `EXISTS`; after 20 empty polls the sleep doubles with every further empty poll up to 50 ms (new parameters `p_idle_max_ms`, `p_idle_polls`;
   existing calls `call mc.run_generator(64, 5)` are unchanged).  Cost: a chunk request that arrives while a generator has backed off waits at most 50 ms (5 ms before) for it to wake; the first poll after work starts again at 5 ms.
7. **One chat message got cheaper** (`mc.chat_broadcast`, `sql/802`): every recipient's `player_chat` differs from the others only in the global index, so everything after it is built once and per recipient only `varint(index) || tail` is framed;
   the function runs with `plan_cache_mode = force_generic_plan` because the statement was planned again for every message (3.2 ms of planning per message at any player count).  Chat statement 2.9 ms (50 players) / 7.1 ms (200) against 5.4 / 12.5 before, byte-identical (`tests/sql/802`).

The switch `set dbcraft.quiet_tick = 'off'` (session, role or database) turns items 1-3 and the keep-alive probe off and runs every phase as before; the tests compare both ways.

### Gateways (`gateway/src/gateway.rs`, `sql/optional/dev_gateway.sql`)

* **Lean ticks** (Rust `lean_ticks`, default on; PL/Python the same rule): a tick with no new socket, no inbound frame, no key response, no verdict and no closed socket runs `select mc.server_tick()` as one autocommit statement and `select net.gateway_pending($1)`;
  the outbox is drained and the control rows read only when the probe says so.  The statistics row (`net.gateway_control`: ticks, last/max tick, late ticks, connections, and the stop flag) is written every 10th lean tick, counting all of them, so a stop request is acted on within 0.5 s.
  Nothing else changes: the 20 Hz schedule is the same code, keep-alives and time packets come from the SQL tick as before.
* **`client_tick_end` filter** (Rust `skip_tick_end`, default on): the same rule as item 3, applied before the database is called, so that idle players leave the inbound queue empty and their ticks are lean too.  (The PL/Python gateway does not know which connections are in play and does not do this.)
* **Urgent chat lane** (Rust `urgent_chat`, default on; PL/Python the same): see the next section.

## Chat latency: the critical path, and what is safe to change

A chat message in the tick path: client write, **gateway read** (the Rust loop is in `epoll_wait` and reads the socket at once; the PL/Python loop is in `select`, same), **wait for the next tick** (uniform over 0-50 ms, mean 25: the frame sits in the gateway's
inbound list), `COPY` into `net.inbox`, **the tick** (classification, movement, chat, ..., chunk streaming, drain: the chat packet is produced in the middle and leaves with everything else at the end, so it waits for the rest of the tick), `drain_outbox`, socket writes, client read.
At 50 idle players that was about 25 (wait) + 5 (tick) + 3 (gateway statements) + the client, and the measured p50 was 34-46 ms; at 200 players the tick part grows to 8-18 ms.  The wait for the tick is half of it and cannot be cut by making the tick faster.

Two ways to cut it were considered:

1. **An early tick** (the gateway wakes at the arrival of a chat frame and runs the tick at once when the budget allows).  Rejected: a tick is the unit of game time.  Running one early either adds a tick (the world's clock runs fast for that interval, keep-alive and
   movement rules count ticks) or moves the next one earlier (two ticks 5 ms apart, one 95 ms apart), which breaks the 20 Hz timing that clients and the movement-speed checks are built on.  The brief said the timing semantics must not change; this one would.
2. **An urgent lane** (done): handle only the chat packet, between ticks, in its own transaction.  The tick is untouched.

How the lane works: when the Rust gateway reads a `chat` frame from a connection it knows is in play, and the next tick is further away than the measured cost of the last urgent run plus `urgent_reserve_ms` (4), it calls
`net.urgent_chat(conns, payloads)` and `net.drain_outbox()` in one transaction right after the socket reads.  `net.urgent_chat` puts the frames into `mc.play_in_work`, runs the **same** `mc.apply_chat` the tick runs, and moves `mc.play_out` into `net.outbox` with the **same** drain statement
(`mc.drain_play_out`, compared with the tick's byte for byte, compressing connections included).  Frames it did not take (connection unknown, not in play, closing, no player, not a chat packet, or behind a frame of the same connection that was not taken) are handed back and travel with the tick.
At most `urgent_max_per_tick` (4) runs happen between two ticks, so a chat flood cannot starve the tick; a failed run is rolled back and its frames are simply left for the tick.

**What can differ from the tick path, and why it is vanilla-compatible.**  The bytes of every packet are identical (`tests/sql/801`: for the same frames, the same bytes reach every connection and the players and chat log end in the same state, with a compressing
connection, an empty message, an illegal character that kicks, frames from connections that are not in play).  What changes is *when* the packet leaves (up to one tick earlier) and *where it stands among the other frames in a recipient's stream*:
in the tick path chat followed that tick's movement and block packets, now it precedes them.  Two orders matter in vanilla and are kept: **arrival order between chat and commands** (a command, or anything behind a command in the inbound list, is never taken: the gateway stops scanning at the first
command frame, so a chat that arrived after a command waits behind it) and **a connection's own order** (a chat frame is only taken when every earlier frame of that connection in the window is chat, `client_tick_end` or a movement packet).  A chat message is not tied to a tick in
vanilla either: from my reading of the server's structure (not re-verified against this jar's bytecode in this work), the network threads hand a chat packet to the main thread as a task and the main thread runs queued tasks while it waits for the next tick, so a chat on an idle
vanilla server is handled at arrival, not at the next tick boundary.  The scoreboard's 24.7 ms vanilla p50 with 50 idle players is a busy vanilla tick (40 ms mean) in the way, not a boundary.

What it does **not** protect: it was not compared with a real vanilla client in a chat-heavy session (there was no such recording to replay), the real-client and vanilla comparison suites (`tests/e2e`, `tests/gateway/run_e2e_rust.sh`) cover chat only through the tick-path-equivalent bytes, and the lane is a new place where
a bug in `mc.apply_chat` would show (it runs outside the tick's per-phase error handling: an exception rolls the transaction back and the frames go through the tick, where the old handling applies).  `urgent_chat = false` turns it off.

**Checked against real vanilla traffic.**  `tests/gateway/run_e2e_rust.sh` (real TCP clients against the recordings of the vanilla server: login, join burst, 49 chunks, block changes, chunk streaming, two players joining, chatting and leaving) passes through the Rust gateway with the new code: 47 comparisons, 0 failures.  In that run the chat message did not
travel the urgent lane (`urgent chat: 0 runs`: the lane needs the next tick to be at least about 6 ms away and the message arrived in the last few), so the "two players: join, chat, leave" comparison was run four more times on its own (once with `urgent_reserve_ms = 0`, three times with the defaults); the lane took the message every time (`urgent chat: 1 runs took 1 frames` in each gateway log) and
each run passed all 18 checks, including `player_chat` identical to vanilla's up to and including the text.

## Proof that the bytes are the same

| test | what it proves |
|---|---|
| `tests/sql/800_idle_tick.sql` (125 checks) | the quiet predicate flips for each of 16 things (a connection, a frame in the inbox, an online player row, a claimed packet, a verdict, a parked login, an active login gate, a kick, a queued frame, a wanted chunk, a block event, a pending acknowledgement, a block actor, a batch frame, entities on, the hook); the quiet tick and the full tick (`dbcraft.quiet_tick = 'off'`) leave the same state after 45 ticks (default and batched entry points), the same log trimming, and the once-a-second truncation; `mc.moves_idle()` is true exactly when `mc.apply_player_moves` changes nothing (70 random states: players moved by other code, every movement packet kind); **whole ticks, 8 players, 40 ticks, 6 seeds per entry point, switch on against switch off**: client_tick_end for everybody, positions, two positions with a tick end between them (the case the tick-end filter must not break), two positions without (a kick), a malformed position packet, chat (some illegal), keep-alive answers and teleport confirmations, one connection with compression: the bytes of every drain (per connection) and the state of every player, connection, `mc.visible`, kicks, errors are equal |
| `tests/sql/801_urgent_chat.sql` (13) | the lane against the tick on the same frames: same bytes per connection, same state; hand-backs; ordering within a connection; commands never taken; `mc.drain_play_out` |
| `tests/sql/802_chat_broadcast.sql` (38) | `mc.chat_broadcast` against the statement it replaced, kept in the test as the oracle: global indices of 1, 2, 3 and 4 bytes, multi-byte texts, 256 characters, recipients ordered by entity id |
| gateway unit tests (55) | `urgent_candidates` (what may be taken, in which order), `drop_idle_tick_ends`, the new settings |
| the existing suite | 57 files, 1,796 checks, all pass, including the replays of the real vanilla traffic (`410`, `385`) and the batched-against-default differential tests (`387`, `388`), `tools/check_overrides.py`, the inlining guard and the clean-migration check (run with `tests/sql/prun.sh`, 2 jobs, 347 s) |

Mutations that were checked to be caught: `mc.moves_idle()` always true (800 part 3 fails); the tick-end filter changed to "never queue a tick end" (the whole-tick comparison of part 4 fails: the connection with a tick end between two positions is kicked).

## What did not work, what is not done

* **The lean tick alone did nothing for idle players**: with 50 or 200 players every tick has inbound frames (their `client_tick_end`), so only 162 of 1,537 ticks of a first test run were lean.  Dropping the tick-end frames in the gateway is what made it apply.
* **Profiling with `pg_stat_statements` costs**: the per-statement numbers above come from a cluster with `track = all` and `track_planning = on`, which inflates every statement by about 20-30%; the before/after table was measured without it.
* **Not done: the PL/Python gateway's tick-end filter** (it does not know the play state); its idle-with-players numbers are therefore better in SQL than in the loop.
* **Not done: vanilla re-measured** on this machine for the table (see the sentence under it).
* **The remaining idle cost** (0 players): see "What is left".
* **Chat p99**: the lane removes the wait for the tick, not the wait behind a tick that is already running: a chat that arrives during a 50-150 ms tick (the keep-alive round, a join) still waits for it.  The tail is bounded by the longest tick, not by the lane.

## What is left

With nobody connected (0.033 cores; per process, 30 s): the gateway's database connection 0.016 (a tick is 0.10 ms of SQL plus two statements per tick through libpq, and every tenth tick a third), the maintenance thread 0.005 (a `VACUUM (ANALYZE)` of 12 small tables every 5 s: it could skip a pass when nothing changed), the gateway process 0.004, the two generators 0.004 each, walwriter 0.001.
Nothing here is large any more; the next saving would be the vacuum thread and a smaller predicate (15 probes: one `pg_class` flag set by triggers could replace them, not worth its complexity at 0.1 ms).

With idle players (200: 2.1 ms SQL tick against 5.1; 3.3 ms measured through the gateway): what remains is a handful of per-statement fixed costs of 0.05-0.2 ms each that the profile (taken before the tick-end filter, so only the order is reliable) listed after the classification: the chunk-streaming scan of `net.conn` x `mc.player` (0.2-0.4 ms at 200),
`mc.refresh_visibility` (0.1), `mc.moves_idle` (0.1), the login gate's property lookups (0.07-0.17), `mc.keepalive_due` (0.06-0.19), the two `count(*)` over online players (0.11 each), the once-a-second housekeeping tick (p95 is 2-3 times the p50), and every 15 s the keep-alive round (every player answers within a few ticks: 332 of 801 ticks of a profile ran the answer path, 0.8 ms
each).  Each could be gated like moves; none is large.  **Idle players on the PL/Python gateway** still cost 6.8 ms at 200 because it does not filter `client_tick_end` (it does not know which connections are in play).
**Chat from real clients**: the lane only takes a chat frame whose connection has nothing but `chat`, `client_tick_end` and movement ahead of it in the tick window.  A real client also sends `player_input`, `swing`, `player_command`, ... when playing; a chat that arrives behind one of them waits for the tick (correct, 25 ms slower).  Widening the list means deciding, packet kind by packet kind, that the chat may overtake it:
not done, and not measurable with the scripted clients (they send only the two kinds).
**The tick itself**: a tick that is already running delays the lane (single-threaded gateway): the p99 follows the longest tick, which is the login storm and the keep-alive round, not idle.

## Noise, and how far to trust the numbers

* The machine is shared with other agents' jobs (load average 0.2 to 4.8 at the start of the matrix runs; every run records it in `tools/scoreboard` results as `load_before`).  Each cell is 3 repetitions, interleaved before/after with the order alternating, median and [min-max].  A difference smaller than the ranges is not a result; the ones in the table are several times larger.
* CPU is cores over the 60 s window, tick time is the SQL tick (it excludes the gateway loop for both gateways, as in the scoreboard).
* The chat percentile of a single run rests on about 60 round trips (one a second): the p99 columns are the p99 of a few dozen samples, i.e. roughly the second-worst; use the p50 for comparisons.
* One run was lost to my own interference and re-run: while the matrix ran the machine's disk was almost full and I truncated the chunk tables of the cluster under test to free space; that run (after, PL/Python, 200 players, first repetition) recorded no chat round trip and took 313 s.  Its record is not in the table (kept in a side file) and the cell was run again once.  The disk was full twice during the work (other jobs on the same volume); runs after that used `SCORE_TRIM_AT_STOP=1`.

## Reproduce

```
tools/scoreboard/idle_matrix.py --before WRAPPER_BEFORE --after WRAPPER_AFTER --reps 3 --hold 60       # two checkouts, two clusters (SCORE_PGDATA, SCORE_PGPORT, SCORE_GW_PORT, SCORE_OUT)
python3 tools/scoreboard/idle_report.py docs/perf-idle-results.jsonl.txt     # the raw results of the table above (dbcraft rows tagged idle:*, vanilla rows vanilla:*)
tests/bench/tick/run.sh 200 100 0.0 300 label       # the SQL tick alone with only client_tick_end input (idle players), no gateway
tests/sql/prun.sh 80[0-2]                           # the new tests (800-802); tests/sql/prun.sh for the whole suite
gateway/build.sh test                               # gateway unit tests
```

## Files

| File | Contents |
|---|---|
| `sql/800_idle_tick.sql` | the quiet tick, `mc.moves_idle`, the hook, the constant id arrays; the header lists every in-place edit |
| `sql/801_urgent_chat.sql` | `net.gateway_pending`, `mc.drain_play_out`, `net.urgent_chat` |
| `sql/802_chat_broadcast.sql` | `mc.chat_broadcast` |
| `gateway/src/gateway.rs`, `config.rs`, `reader.rs` | lean ticks, tick-end filter, urgent lane, settings |
| `sql/optional/dev_gateway.sql` | lean ticks and the urgent lane in the PL/Python gateway |
| `tools/scoreboard/idle_matrix.py`, `idle_report.py` | the before/after runner and its table; `dbcraft.sh` / `common.py` / `vanilla.sh` got `SCORE_*` overrides for ports and directories, `SCORE_GATEWAY=rust` and `SCORE_TRIM_AT_STOP` |
