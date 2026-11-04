# Idle cost, chat from real clients and the tick tail: the second round

[PERF-IDLE.md](PERF-IDLE.md) closed the scoreboard's idle losses for the PL/Python gateway and for scripted clients, and left four things open (its "What is left"): an empty server still used a little more CPU than vanilla
(0.022-0.030 cores against 0.017-0.019), idle players still cost a full tick, the lane for urgent chat only took chat that had nothing but `client_tick_end` and movement ahead of it (real clients send more), and the p99 of the tick
(and so of chat) followed the longest tick.  This document is that round: what was measured first, what changed, what the numbers are now with vanilla re-measured in the same session, what did not work and what is still a loss.

## Result

Same machine for everything (4 vCPUs shared with about eight other agents' jobs; **the load average at the start of the cells was 0.2-7, median 2-3, see "Noise"**), Rust gateway, world pre-generated, view distance 10, idle bots that send `client_tick_end` every tick plus one chat probe (one message a second, timed
until its broadcast comes back).  **Before** is `046d1e2`, the commit this work started from (its own checkout, own cluster, its own gateway binary, the *same* load generator and runner); **after** is this branch; **vanilla** is the real 26.3 server (`-Xms2G -Xmx2G`).
The three alternate inside every repetition (the order rotates), 3 repetitions of 60 s per cell (`tools/scoreboard/idle2_matrix.py`); medians with [min-max].  CPU is **every process of the cluster plus the gateway process** (see the correction below).
One "after" cell (200 players, repetition 1) could not start its gateway (`Address already in use`: a harness collision) and was run again; it is the slowest of the three.

| players | server | runs | tick mean ms | tick p99 ms | CPU cores | chat p50 ms | chat p99 ms | load before |
|---|---|---|---|---|---|---|---|---|
| 0 | vanilla | 3 | 0.41 [0.41-0.46] | 1.1 [1.0-3.7] | 0.020 [0.019-0.021] | - | - | 3.9 [0.2-5.0] |
| 0 | before | 3 | 0.16 [0.14-0.16] | 0.6 [0.5-0.6] | 0.041 [0.038-0.044] | - | - | 3.2 [1.3-4.0] |
| 0 | **after** | 3 | 0.12 [0.10-0.13] | 0.2 [0.1-0.2] | **0.019 [0.016-0.022]** | - | - | 2.6 [0.5-7.0] |
| 50 | vanilla | 3 | 47.24 [46.95-49.98] | 81.8 [78.8-88.0] | 1.122 [1.096-1.237] | 29 [29-37] | 73 [72-77] | 1.6 [0.3-2.2] |
| 50 | before | 3 | 3.90 [3.66-3.95] | 13.7 [13.6-13.8] | 0.147 [0.135-0.149] | 10 [8-13] | 25 [25-31] | 2.3 [0.4-5.3] |
| 50 | **after** | 3 | 3.11 [2.97-3.25] | 9.9 [9.5-9.9] | **0.114 [0.106-0.119]** | 8 [8-11] | 24 [22-26] | 2.5 [0.5-2.6] |
| 200 | vanilla | 3 | 74.94 [69.41-163.38] | 147.9 [135.4-352.9] | 1.431 [0.975-1.452] | 51 [43-78] | 108 [90-264] | 1.0 [0.7-1.1] |
| 200 | before | 3 | 5.68 [5.41-5.81] | 18.2 [17.6-20.8] | 0.231 [0.228-0.244] | 15 [14-25] | 39 [38-55] | 2.9 [2.6-2.9] |
| 200 | **after** | 3 | 5.01 [4.62-6.46] | 13.0 [11.2-24.8] | **0.195 [0.169-0.207]** | 14 [13-35] | 37 [31-88] | 2.0 [1.3-3.3] |

"Tick" is vanilla's own `/tick query` and, for dbcraft, `ms_total` of `mc.server_tick_log` (the SQL tick).  An earlier pass of the same matrix, on a busier machine (load 3-11) and with the queue-truncation setting of the tail section still at its old behaviour, gave the same picture
(empty server 0.015 [0.012-0.017] after, 0.030 before, 0.017 vanilla; 50 players 0.098 / 0.113 / 1.14; 200 players 0.177 / 0.205 / 0.97 with tick means 4.4 / 4.4 / 57 and 5.3 / 6.2 / 149 ms): its raw lines are in the results file too.

**What this says, plainly.**

* **Empty server: 0.019 [0.016-0.022] cores against vanilla's 0.020 [0.019-0.021]: a tie, and half of the 0.041 it was** (the earlier pass: 0.015 against 0.017 and 0.030).  The loss against vanilla is closed to within what these measurements can resolve (the machine's own noise at this size is about 0.003 cores); the
  claim "at or below vanilla" holds on the medians (0.019 < 0.020, 0.015 < 0.017) but not beyond the ranges.  Tick time: 0.12 ms against vanilla's 0.41.  Per process ("Where the CPU of an empty server was"): the tick connection 0.0133 -> 0.0073, the two generators 0.0058 -> 0, the gateway 0.0025 -> 0.0018.
* **50 and 200 idle players: 22% and 16% less CPU than before (0.147 -> 0.114, 0.231 -> 0.195; the ranges do not overlap) and 9.8 and 7.3 times less than vanilla** (1.12 and 1.43 cores; vanilla's tick is 47 and 75 ms, with a p99 of 82 and 148).  The tick is 20% shorter at 50 players (3.11 against 3.90 ms) and 12% at 200 (5.01 against 5.68),
  its p99 28% and 29% shorter (9.9 against 13.7, 13.0 against 18.2 ms), without any change to what the phases do: it is the guards, the once-a-second trims and, at 200 players, the truncate bound (the tail section).  What is not gone: the cost is still the full tick (2.7 ms at 200 players in `pg_stat_statements`, a dozen phases owned by other tracks) and 4,000 socket reads a second in the gateway (0.028 cores).
* **Chat with idle players, scripted client (only `client_tick_end` ahead of the chat): p50 8 ms at 50 players and 14 at 200 against vanilla's 29 and 51, p99 24 and 37 against 73 and 108; before this work 10 and 15 / 25 and 39** (the lane was already there; the change is a few ms at p50, inside the ranges at 200).

### Chat from real clients (new)

`tools/scoreboard/loadgen.py --realistic 1`: every bot also sends what a real client sends besides `client_tick_end` and movement (`player_input` when it changes direction, `punch`, `player_command`, `set_carried_item`, `move_player_pos_rot`, a few a minute per bot), and the chat probe sends one to three of
those kinds, each 0-50 ms **before** every chat, so they land in the same 50 ms window as the chat about as often as real traffic would (with the old rule 29% of the chats were kept out of the lane by something ahead of them).  50 idle players, 90 s, 4 repetitions each (360 chats per build), before and after alternating
(`idle2_matrix.py --servers before,after --sizes 50 --realistic 1 --hold 90`):

| build | CPU cores | chat p50 ms | chat p99 ms | chats under 26 ms | taken by the lane | went to the tick |
|---|---|---|---|---|---|---|
| before | 0.136 [0.126-0.151] | 31 [25-36] | 73 [61-87] | 41% | 113 of 360 (31%) | 247 (blocked by another frame of their connection or too late) |
| **after** | 0.114 [0.108-0.124] | **20 [18-23]** | 76 [69-79] | **61%** | 218 of 360 (61%) | 142, **all of them takeable but late** (the tick was due within the lane's price), **none blocked** |

The extension does what it was built for: a chat is no longer kept from the lane by what stands ahead of it (the gateway now counts why a chat went to the tick: 0 of 142 were behind another frame of their connection, 0 behind a command, 0 not in play).  The p50 gain, 31 -> 20 ms (11 ms), is real (the ranges do not overlap) and the
p99 is unchanged: **the lane still stays out of the way when the next tick is nearer than its own price** (its measured SQL cost, 6-12 ms with 50 players on this machine, plus 4 ms of reserve), which is 39% of the chats; those wait for the tick, which on average is not far away.
An earlier run with 3 repetitions (and one with a probe that was kicked by my own load generator: two position packets in a window; fixed, `random.sample`) showed no difference at all: the effect is real but needs hundreds of chats to be seen on a noisy machine.

### The tail of the tick (new)

At 200 idle players the slowest SQL ticks of a steady minute were **all the first tick of a second** (position 0 of the 20 ticks of a second, mean 13-21 ms against 4-5 for the others, `by_residue` in the result files; the next tick, position 1, 9-13 ms), and their time was in `net.process` (8-26 ms), not in
work: the tick truncates `mc.play_in_work` and `net.batch` (game time 19 mod 20) and `mc.play_out` (0 mod 20) once a second **whenever they were written** (sql/435: DELETE leaves dead rows), and **a TRUNCATE invalidates every cached plan that mentions the table, so the next tick plans them again** (`pg_stat_statements`:
`delete from mc.server_tick_log ...` 0.11 ms of planning on every call, and a `net.drain_outbox()` straight after a `truncate net.outbox` took 9-13 ms against 0.4-0.6 in a quick test in one session on the busy machine).  New setting `dbcraft.tick-truncate-bytes` (default **256 KiB**, `0` is the old behaviour): the queues are truncated only when they are bigger than that.
`tail_matrix.py`, 200 idle players, alternating, steady state only (the three values of a cell are its repetitions in order):

| `dbcraft.tick-truncate-bytes` | SQL tick mean ms | SQL tick p99 ms | gateway tick mean ms | gateway tick p99 ms | ticks over 50 ms (of ~1,120) | CPU cores | first tick of a second, mean ms |
|---|---|---|---|---|---|---|---|
| 0 (every second; before) | 5.60 / 6.47 / 5.43 | 20.6 / 29.8 / 18.3 | 8.39 / 11.49 / 7.87 | 30.5 / 42.6 / 25.3 | 1 / 7 / 0 | 0.22 / 0.18 / 0.22 | 14.3 / 20.9 / 13.4 |
| 1,048,576 | 4.46 / 4.83 / 4.21 | 13.0 / 18.1 / 11.6 | 6.93 / 8.69 / 6.58 | 19.4 / 25.9 / 17.8 | 0 / 2 / 0 | 0.20 / 0.17 / 0.19 | 6.4 / 7.0 / 6.2 |
| **262,144 (the default)**, a second series | 4.40 / 5.71 | 15.3 / 21.6 | 6.96 / 9.95 | 21.8 / 31.8 | 0 / 0 | 0.20 / 0.19 | 8.4 / 9.2 |
| 0, the same second series | 4.68 / 6.82 | 15.4 / 30.2 | 6.99 / 11.66 | 24.3 / 45.8 | 0 / 7 | 0.20 / 0.19 | 12.4 / 21.1 |

("gateway tick" is the whole tick as the Rust gateway saw it, from `tools/scoreboard/tick_tail.py`: statements, the read of the drain, the socket writes.)  With the truncate every second the first tick of the second costs 13-21 ms against 4-5 for the others
(`mc.server_tick_log` by position in the second, in the result files) and the slowest ticks of a minute are all of them; a bound of 1 MiB removes the effect (p99 -36%, mean -17%), 256 KiB most of it (p99 -10% and -30% in two repetitions: the second series is the noisier one, load 1.1-4.4).
**Walking players do not gain**: with 50 walkers (`tailB`, 3 repetitions, 1 MiB against 0) the queues are bigger than the bound every second anyway, the p99 of the gateway tick is 37.8-41.9 against 38.2-46.0 ms, and the *mean* is worse with the 1 MiB bound (SQL tick 14.1-14.8 against 11.9-13.7 ms, CPU 0.43-0.45 against 0.40-0.43):
a bigger table is read dead rows and all by every tick.  That is why the default is the smaller bound: idle players get the benefit, walkers keep the old behaviour (their queues are over 256 KiB each second).  The first tick of the second is still the worst for walkers (25 ms against 12, the time packet and the truncate), which this setting cannot fix.
The keep-alive round did **not** show up as a tail source: no slow tick sits at a position that is a multiple of the keep-alive period, the answers cost 0.5 ms a call (`pg_stat_statements`), and the first keep-alive of every player is 15 s after its join so the rounds are spread over the join spread.

## A correction to the numbers of PERF-IDLE.md (read this first)

`tools/scoreboard/run.py` measured dbcraft's CPU as the CPU of the PostgreSQL process tree.  The Rust gateway is not a child of the postmaster, so **the "CPU cores" of every Rust row in PERF-IDLE.md (0.030, 0.076, 0.107, ...) leaves the gateway process out**
(the PL/Python gateway is a backend inside the tree, its rows were right).  `dbcraft.sh start` now writes the gateway's pid to `$SCORE_OUT/gateway.pid` and the runner adds that process.  At 200 idle players the gateway costs 0.028 cores
(4,000 `client_tick_end` frames a second, one `read` each, about 1,000 context switches a second), so that row's 0.107 was about 0.135 with it.  Every number in this document includes the gateway; the "before" column is the code this work started from, measured the same way, in the same session.

## Where the CPU of an empty server was (measured first)

Per process, empty server, Rust gateway, 60 s, `tools/scoreboard/idle_cpu.py` (cores from `/proc/<pid>/stat`; this machine was busy, load average 7-16, so read the shares, not the third decimal):

| process | before (`046d1e2`) | after | what it did |
|---|---|---|---|
| the gateway's database connection (the tick) | 0.0133-0.0138 | 0.0073 | 20 ticks a second |
| the two chunk generators | 0.0030 + 0.0028 | 0 (parked) | `call mc.run_generator(64, 5)`: a poll every 50 ms for ever |
| the gateway process | 0.0025 (63 context switches/s) | 0.0018 (42/s) | epoll loop, one tick every 50 ms |
| maintenance thread (vacuum) | 0.0008 | 0.0007 | `VACUUM (ANALYZE)` of 12 tables every 5 s |
| walwriter, background writer | 0.0005 | 0.0003 | |
| **total** | **0.0230-0.0242** | **0.0102** | vanilla, same session: 0.017-0.018 |

What a tick cost the connection, in microseconds of backend CPU per call (pgbench at 200 calls a second against the idle cluster, `select 1` = the cost of the round trip itself, 57-93): the quiet tick 300-340, then the gateway's second statement
(`net.gateway_pending`) 70-165 more; after this work one prepared statement, 190-250 together.  `strace -c` of the backend: 22 `lseek` per tick (each of the 17 probes opens its relation and asks for its size) before, 4 after.

## What changed

1. **A quiet tick that skips its own 17 probes** (`mc.tick_quiet`, `sql/800`).  The predicate is one probe per queue table (empty tables, 0.13 ms of an idle tick that is 0.15 ms otherwise).  Every one of those tables can only change through a transaction that has a
   transaction id, and a snapshot's `xmax` is "the newest completed id + 1".  The tick takes its own id M first (it writes the clock anyway) and then a snapshot; if that snapshot has `xmax = M` and `xmin = xmax` (nothing with a smaller id is running), the tick
   remembers `M + 1` in a session setting (`dbcraft.quiet_mark`).  The next tick, again in its own transaction, compares its snapshot's `xmax` with the mark: equal means no other transaction has completed since the probes found everything empty, so
   they need not be repeated (a transaction with a higher id raises `xmax` when it commits or aborts, one that has not completed is invisible).  Not used when the transaction already has an id (it may have written to a probed table itself: tests and admin scripts
   that write and then tick in one transaction), when the switch `dbcraft.quiet_tick = 'off'` is set, or when the hook `mc.tick_extra_pending()` says so (it is asked every tick: it may depend on a clock).  An aborted transaction restores the old mark, which can only make a probe run.
   Two more probes joined the list: `net.outbox` and `mc.chunk_request` (below).  **Proof**: `tests/sql/970_quiet_gate.sql` (88 checks): for each of 18 things that make a tick not quiet, "two quiet ticks (armed), the change by another transaction, `mc.tick_quiet()`" says not quiet; the same with a second session (dblink):
   a row committed between two ticks, a transaction in flight while a tick runs and committing after it, one that begins after an armed tick, a rollback, **the hole an `xmax`-only gate would have** (a transaction holding an id below a completed one commits later: the commit raises nothing, only `xmin` shows it), a write in the
   tick's own transaction, the hook; and the number of probe rounds of 100 idle ticks of one session is at most 3.  **Mutants checked**: the gate ignoring `xmax`; usable inside a transaction that has written; always arming; arming without the `xmin` condition; dropping the outbox probe: each is caught by `970` (the outbox one by `800` too).
2. **One log row a second, not one per tick** (`mc.tick_quiet_step`).  The row of `mc.server_tick_log` costs 0.09 ms, more than the whole rest of a quiet tick, and says "nothing happened" twenty times a second.  A quiet tick now writes it on the tick whose game time is a multiple of 20
   (the one that also does the once-a-second housekeeping), `ms_total` being the time of the clock update and the leftover check (what every quiet tick costs).  A full tick still logs every tick.  The scoreboard computes tick time per row, so the idle "tick mean" is a mean over one tick in twenty
   of the same quantity.
3. **One round trip and a prepared statement for the lean tick** (gateway): `select mc.server_tick(), net.gateway_pending($1)` (the probe sees the tick's writes: same transaction), prepared once per connection (`PQprepare`/`PQexecPrepared` in `ffi/pq.rs`, forgotten on a reset);
   the statistics row every 20th lean tick instead of every 10th (a stop request is acted on within 1 s).  `net.gateway_pending` answers 0 without probing when the quiet tick of **the same transaction** found nobody connected, the outbox and the request queue empty (`dbcraft.quiet_xid`;
   used up by the call, so a second call in the transaction probes).
4. **Chunk generators that cost nothing while idle** (`sql/970`, `gateway/src/generators.rs`).  New setting `generators`: threads of the gateway with a connection each, running `call mc.run_generator_until_idle()` (the loop of `mc.run_generator`, but it *returns* after `generator_exit_idle_ms` without a request)
   and parked on a condition variable otherwise.  The tick's probe (`net.gateway_pending` bit 4: a row in `mc.chunk_request`; the request queue is part of the quiet predicate so the shortcut cannot hide it) wakes them: a request waits for a generator one tick plus at most one 5 ms poll, as before.
   Default 0 (inline generation, or loops started by hand, which still work); `tools/scoreboard/dbcraft.sh` uses 2 threads for the Rust gateway (`SCORE_PSQL_GENERATORS=1` brings back the psql loops for the old gateway).
5. **The maintenance thread sleeps on a condition variable** instead of waking five times a second to look at the clock.
6. **A partial index on the connections that are closing** (`sql/972`): `net.gateway_pending`, `net.drain_outbox` and the tick's drain asked "is any connection closing?" with a scan of `net.conn` (30 pages for 200 players: the rows are updated by the keep-alive bookkeeping),
   0.1-0.3 ms of every tick with players.
7. **Phases of the full tick that have nothing to do are not entered** (`mc.server_tick`, `sql/430`; the switch `dbcraft.quiet_tick = 'off'` runs them all): block actions, block-event broadcast, kicks/leavers and the drain are guarded by the one query each already makes first thing
   (`pg_stat_statements`, 200 idle players: each phase cost 0.05-0.15 ms for its call, its declarations and its savepoint before it found nothing).  **The trims of the tick logs run once a second** (`delete from mc.server_tick_log where tick < cur - 6000` and the same for `mc.tick_log` were planned
   again on every call, 0.11 and 0.09 ms of planning plus the same again to run): `sql/430`, `sql/389` and, the one edit to a function others are changing, **`mc.tick_core` in `sql/837`: `if cur % 20 = 0 then delete from mc.tick_log ... end if;` and nothing else**.
8. **The once-a-second truncation of the tick's own queues is bounded** (`dbcraft.tick-truncate-bytes`, default 256 KiB, `0` = the old behaviour; `mc.server_tick` in `sql/430`, the setting in `sql/972`): the commonest long tick of an idle server with players was the one after the truncate (see "The tail of the tick").
9. **The PL/Python gateway** (`sql/optional/dev_gateway.sql`) filters `client_tick_end` of connections in play like the Rust gateway (the play state comes from `net.gateway_ctl`) and takes the neutral kinds from the database.

## Chat from real clients

The lane (`PERF-IDLE.md`) took a chat only when everything ahead of it from the same connection was chat, `client_tick_end` or movement.  A real client also sends `player_input`, `punch` (the swing; 26.3 calls it that), `player_command`, `set_carried_item`, ...; behind one of those
a chat waited for the tick (25 ms slower on average).  The rule now takes the kinds that cannot change what a chat does or sends, **decided from the vanilla jar and from this server's SQL, kind by kind** (`sql/971`, `tests/sql/971_urgent_neutral.sql`).

**The vanilla half** (`tools/jar_handlers.py` over `javap -c -p` of `ServerGamePacketListenerImpl` and `ServerCommonPacketListenerImpl`, 26.3): of the 61 play handlers, 51 start with `PacketUtils.ensureRunningOnSameThread` (the body is queued on the main thread, first come first served,
across all connections) and 10 run on the network thread at arrival (`chat`, `chat_command`, `chat_command_signed`, `chat_ack`, `custom_payload`, `ping_request`, `sign_update`, `edit_book`, `command suggestions`, `configuration_acknowledged`); in the common listener `keep_alive`, `pong` and `cookie_response` run on the network thread too.
**`handleChat` itself does not wait for the main thread**: `tryHandleChat` checks the characters (disconnect on illegal ones) and the chat visibility and answers "chat disabled" on the network thread, then queues the message with `MinecraftServer.execute`.  (So a chat is "handled at arrival" as far as vanilla
can tell: the previous document's claim, which it said was not verified, is right.)  Only five handlers touch the chat machinery (the signed chain's last-seen validator, the chat session, the message chain): `chat`, `chat_command`, `chat_command_signed`, `chat_ack`, `chat_session_update`;
`client_information` changes the player's options, which include the chat visibility `tryHandleChat` reads (this server has no hidden chat, in either path); `set_command_block`, `set_command_minecart` and `set_structure_block` only send an error message to their own sender.
Everything else has no connection to chat, and for the 51 queued handlers there is no order between a chat and a neighbour to preserve beyond arrival order of the chat with commands, which the lane keeps (a command stops everything behind it, whoever sent it).

**The dbcraft half**: the lane runs `mc.apply_chat` before the rest of the window's frames, the tick after them; a kind is neutral when what the tick does with it neither reads nor writes what `mc.apply_chat` reads or writes (the sender's name, uuid and `chat_sent`, every recipient's connection and `chat_recv`, `mc.chat_log`).
That is tested, not argued: `tests/sql/971` sends each of the 36 neutral kinds (empty body, eight zero bytes, and the right shape where the tick parses one: `client_information`, `set_carried_item`, `player_command`, `player_action`, `use_item_on`, `use_item`, `client_command`, movement ...) ahead of a chat once through the tick
and once through the lane, and compares **every column of every player, the connections, the chat log, the kicks, the clock and the errors, and the set of frames every connection receives**; plus eight random mixes of 40 frames from five players.
The order inside a recipient's stream may differ (the chat now comes first; it used to follow the tick's movement and block packets).  The test can fail: a stand-in for a kind that renames the sender before the chat is built is reported as different.  A protocol update that adds a kind fails the classification check until someone decides.
What stays blocking, on purpose: the commands, `chat_ack`, `chat_session_update`, `command_suggestion`, the commands in disguise (`change_game_mode`, `change_difficulty`, `lock_difficulty`, `set_game_rule`), text input (`edit_book`, `sign_update`, the block-entity editors), `configuration_acknowledged`, and the entity-interaction kinds
(`attack`, `interact`, `teleport_to_entity`, `spectator_action`, `move_vehicle`, `paddle_boat`, `pick_item_from_entity`, `entity_tag_query`, `select_trade`, `set_beacon`, `bundle_item_selected`, `block_entity_tag_query`): dbcraft ignores them today, and whoever gives them effects (entities, containers) decides with the paired test whether a chat may overtake them.
Both gateways read the list from `net.urgent_neutral_play_ids()` at start (restart them after reloading `ref.packet`), and the Rust gateway counts what happens to every chat that reaches the tick: how many were takeable but late (the tick was due), how many stood behind another frame of their connection (with the packet ids that blocked them) and how many behind a command; it logs that at shutdown.

## What did not work, what was not done

* **Two earlier passes of the matrix were not the record.**  The first ran while I ran the SQL test suite in the *same cluster* as the "after" server (the test databases are clones in the cluster, so their sessions counted as the server's CPU: 0.39 and -8.67 cores in two cells), and after I changed a function of the server mid-run.  The kernel's memory cgroup is shared
  by all the agents' jobs: it killed a vanilla JVM (2.2 GB) in the first pass.  The second pass (busy machine, truncate bound still 0) is summarised under the table; the third, on a machine that had become quiet, with the final code, is the table.  Tests run in a cluster of their own (port 59751) since.
* **The chat lane's effect did not show at 3 repetitions** (see above): 270 chats per build was not enough on a loaded box, 360 were; the 3-repetition run also had a probe that my own load generator got kicked (two position packets in one window): the probe silently stopped sending after a few chats.
* **The 50/200-player CPU is 22% and 16% lower**, not "trimmed further" in the way an empty server was: what is left (`pg_stat_statements`, 200 idle players, per call on a busy machine: `net.stream_chunks` 0.66 ms, `mc.refresh_visibility` 0.32, `mc.survival_moves` 0.29, `mc.survival_entities` 0.26, `mc.keepalive_due` 0.19, `net.join_gate` 0.19, `mc.deliver_ready_chunks` 0.17,
  `mc.broadcast_block_events`, `mc.moves_idle` ...) is a dozen phases of 0.1-0.7 ms each, **owned by other tracks** (login storms, visibility, world performance, survival) and not mine to rewrite; the same transaction-id trick can in principle skip a phase when nothing has changed since it last found nothing to do, but it needs a per-phase proof
  that the phase's own output depends on nothing but the tables and not on the tick number (keep-alive and survival do), which I did not do.  The gateway's 4,000 reads a second per 200 players could be batched by waking later (a 200 microsecond coalescing delay would cut the context switches 4 times for 0.2 ms of chat latency); not tried.
* **Not re-measured: the PL/Python gateway's CPU and tick at 200 idle players** (its `client_tick_end` filter and neutral kinds are implemented and `tests/e2e/run_all.sh` passes with them: 47 comparisons; the 6.8 ms of PERF-IDLE.md was not measured again).
* **Not tried: lowering `dbcraft.queue-trim-bytes`** (8 MiB, the bound of `net.drain_outbox()`'s truncation of `net.inbox`/`net.outbox`).  After a join burst the outbox keeps 512 KiB of dead rows at 200 idle players (64 pages: 0.2 ms of `net.gateway_pending`'s `exists` probe on every tick; the partial index took the closing-connection scan away, this one is left);
  a lower bound means more truncates, and a truncate is exactly what the tail section found expensive.  A trim at a moment the tick chooses (once a second, when the queue is empty and bigger than 64 KiB) would do it; not done.
* **A platform fact worth knowing**: `perf` is not installed here; the profile is `pg_stat_statements`, `strace -c`, per-process `/proc` CPU and pgbench micro-measurements at a fixed rate.

## What is still a loss, and what is still not known

* **Empty server CPU: a tie, not a win** (0.019 against 0.020 in the record pass, 0.015 against 0.017 in the earlier one; the ranges overlap).  Vanilla's number is the machine's floor for a JVM at rest; ours is 20 wake-ups a second of two processes.  Further saving would be "skip ticks": not done, because the tick number is the world's clock and observable.
* **Tick time at 50 and 200 idle players** is 3.1 and 5.0 ms against vanilla's 47 and 75 here, a win; but the **p99** (10 and 13 ms SQL, 20-30 ms as the gateway sees it at 200 players) is still mostly the once-a-second work (the time packet for 200 players, the log trim) and the join storm (tick of 0.3-1.6 s while 200 clients log in: not this track).
* **The lane still waits when the tick is near** (39% of the realistic chats); its price is its SQL cost (`mc.chat_broadcast`: 2.9 ms at 50 players on a quiet machine, 6 here).
* **Chat p99** with the realistic client has not moved (73 -> 76 ms; scripted client 25 -> 24 and 39 -> 37 ms): it is the longest tick, as before.  The truncation bound removed the commonest long tick; the keep-alive round did **not** show up as a tail source in these runs (no slow tick sits at a keep-alive position; the answers cost 0.5 ms a call).
* **Walking players**: the tail experiment above (50 walkers) shows no gain from the truncate bound and a first tick of the second at twice the others; the 200-walker soak ends at 71-79 ms against 54-78 for the starting commit (noise-limited, see Tests), and the scoreboard's 200-walking-players kick-out (docs/SOAK.md) was not investigated by this work.
* **Vanilla's numbers on this box are not vanilla's quiet-machine numbers**: its mean tick of 47-75 ms with idle players (37-57 in earlier sessions) and its 0.97-1.43 cores are what the JVM did next to the other jobs.  Read the dbcraft columns as measured and the vanilla columns as "what vanilla did on the same box in the same hour" (the cells alternate).

## Noise, and how far to trust the numbers

* The load average at the start of the cells was 0.2-7 in the record pass (3-11 in the earlier one; it is recorded per run, `load_before`, and is in the table); other agents ran vanilla servers, PostgreSQL clusters and test suites throughout.  CPU numbers are cores over 60 s windows from `/proc` (10 ms resolution: about 0.0002 cores), per-call costs are pgbench at 200 calls a second,
  3 repetitions per cell, medians and ranges; **a difference inside the ranges is not a result** (the empty-server CPU against vanilla; the chat p50 at 50 and 200 scripted players).  The CPU gain at 50/200 players has non-overlapping ranges in the record pass (0.106-0.119 against 0.135-0.149; 0.169-0.207 against 0.228-0.244), overlapping ones in the earlier busy pass (0.097-0.124 against 0.112-0.135), and the realistic-chat runs (4 repetitions, 0.108-0.124 against 0.126-0.151) agree.
* The chat percentiles of a 60 s cell rest on about 60 chats; the realistic comparison pools 360.
* Vanilla ran with `-Xms2G -Xmx2G` as in the scoreboard; one JVM was killed by the shared memory cgroup in the thrown-away pass and one 'rcon closed' run was repeated.
* dbcraft's cluster is the dev cluster (`fsync = off`, `synchronous_commit = off`, in `/dev/shm`), as in the scoreboard; vanilla's world is on tmpfs too.

## Tests

Run on a cluster of their own (`/dev/shm`, port 59751; never the cluster of a measurement):

* **The whole SQL suite** (`tests/sql/prun.sh`, 3 jobs, 734 s on a machine shared with other jobs): **66 files, 2,409 checks, all pass**, with the structural checks the runner ends with (the override list: 59 functions, all listed in `sql/OVERRIDES.txt`; the clean-migration check; the inlining guard).
  New: `tests/sql/970_quiet_gate.sql` (92 checks: the gate, the second session, the pending shortcut, the generator that parks, the truncation bound), `tests/sql/971_urgent_neutral.sql` (48: every kind classified, every neutral kind through the tick and the lane, eight random mixes, the test's own mutation check).
  Changed: `800_idle_tick.sql` (129: the log row once a second instead of per tick; two more probes), `437_tick_churn.sql` and `550_entity_split.sql` (they test the truncation of tiny queues by the tick itself, so they set `dbcraft.tick-truncate-bytes = 0` first: one line each).  `970` waits (up to 15 minutes) until no other database of the cluster is active before it tests the gate,
  because transaction ids are numbered for the whole cluster and a test running in parallel in another database disarms the gate every few milliseconds (correctly): in the first full run `970` failed for that reason.
* **Mutants** (`mutate` of sql/800 against 970 and 800, the file restored afterwards): the gate ignoring `xmax`; usable inside a transaction that has written; always arming; arming without the `xmin` condition; dropping the outbox probe; dropping the chunk-request probe: **all six are caught by `970`** (the last two also by `800`).
* **The gateways**: unit tests `gateway/build.sh test`: 58 gateway tests (3 new: neutral kinds, order with commands, the fate counters) and the core's 30, all pass.  **`tests/gateway/run_e2e_rust.sh`: 47 comparisons with the recordings of the real vanilla server, 0 failures** (the gateway's shutdown line: 2,204 of 2,268 ticks lean, "urgent chat: 1 runs took 1 frames": the chat of the two-player scenario travelled the lane and its
  `player_chat` is identical to vanilla's up to the text).  **`tests/e2e/run_all.sh` (the PL/Python gateway with its new tick-end filter and neutral kinds): 47 comparisons, 0 failures.**
* **The soak guard** (`tests/soak/run.sh rust 6 200`, 200 walking players, 6 minutes): **PASS**, three times for this branch and three times for the starting commit (alternating, same machine): 0 clients dropped, queues bounded, no growth.  The SQL tick of the last sample was 71 / 79 / 79 ms (after) against 54 / 78 / 54 ms (before), ticks per second 10-11 against 12-14: **the 200-walker tick is dominated by the movement and chunk phases of other tracks (the SOAK.md figure of 31 ms is from before them) and
  this work cannot be told apart from the starting commit with three runs each**; with 50 walkers (below) it is not worse.
* **50 walking players** (`idle2_matrix.py --servers before,after --sizes 50 --moving 1.0 --bound 500`, 3 repetitions alternating, load 0.4-0.7): tick mean 11.89 [11.88-12.13] ms after against 13.04 [12.51-15.77] before, p99 27.0 [24.9-27.6] against 30.5 [29.5-37.4], CPU 0.391 [0.391-0.393] against 0.411 [0.395-0.458] cores, chat p50 16 against 21 ms: **not worse, slightly better** (the guards, the log trims, the fused tick).
* **Not run**: `tests/gateway/run_online_rust.sh` (online mode; the encryption and session paths were not touched), the gateway under valgrind (the new code is a prepared statement, a condition variable and two thread loops; `gateway_valgrind.sh` is the tool for it), `tests/gateway/run_load_rust.sh`.

## Reproduce

```
tools/scoreboard/dbcraft.sh start                                  # the Rust gateway with 2 generator threads (SCORE_* variables move cluster, ports, output)
python3 tools/scoreboard/idle_cpu.py --seconds 60                  # CPU per process, gateway included
python3 tools/scoreboard/idle_profile.py --n 200 --hold 40          # per-process CPU, tick percentiles, pg_stat_statements top (when the cluster loads it)
IDLE2_BEFORE=/path/to/checkout-of-046d1e2 python3 tools/scoreboard/idle2_matrix.py --reps 3 --hold 60                      # vanilla / before / after, 0 / 50 / 200 idle players
python3 tools/scoreboard/idle2_report.py FILE [--by-extras]       # the table above;  --realistic 1 --servers before,after --sizes 50 for the chat table
python3 tools/scoreboard/tail_matrix.py --n 200 --moving 0 --values 0,1048576 --key dbcraft.tick-truncate-bytes           # the tail table (the gateway writes its tick log when DBCRAFT_GW_TICK_LOG / SCORE_TICKLOG is set)
python3 tools/scoreboard/tick_tail.py FILE --last 56 --skip 4     # percentiles and the slowest ticks of a gateway tick log
python3 tools/jar_handlers.py javap.txt                           # the handler classification of the chat section (javap -c -p of ServerGamePacketListenerImpl)
tests/sql/prun.sh _quiet; tests/sql/prun.sh _urgent_n; tests/sql/prun.sh _idle      # 970, 971, 800
```

Raw results: `docs/perf-idle2-results.jsonl.txt` (matrix, chat and tail runs, one JSON line each).

## Files

| File | Contents |
|---|---|
| `sql/800_idle_tick.sql` | the gate in `mc.tick_quiet`, one log row a second in `mc.tick_quiet_step` |
| `sql/801_urgent_chat.sql` | `net.gateway_pending` (shortcut, bit 4) |
| `sql/970_generator_idle.sql` | `mc.run_generator_until_idle` |
| `sql/971_urgent_neutral.sql` | `net.urgent_neutral_play_ids()` and the classification argument |
| `sql/972_conn_closing_index.sql` | partial index on closing connections, `dbcraft.tick-truncate-bytes` |
| `sql/430_tick_perf.sql`, `sql/389_batch_tick.sql`, `sql/837_survival_integration.sql` | idle guards, trims once a second, the truncate bound (the 837 diff is one `if`) |
| `gateway/src/gateway.rs`, `generators.rs`, `maint.rs`, `config.rs`, `ffi/pq.rs` | fused prepared tick, neutral kinds, chat statistics, generator threads, condvar maintenance, `tick_log`, `PQprepare` |
| `sql/optional/dev_gateway.sql` | PL/Python gateway: tick-end filter, neutral kinds |
| `tests/sql/970_quiet_gate.sql`, `971_urgent_neutral.sql`, `800_idle_tick.sql` | tests |
| `tools/scoreboard/idle_cpu.py`, `idle_profile.py`, `idle2_matrix.py`, `idle2_report.py`, `tail_matrix.py`, `tick_tail.py`, `loadgen.py` (`--realistic`), `run.py`, `dbcraft.sh` | measurement |
| `tools/jar_handlers.py` | classification of the vanilla handlers |
