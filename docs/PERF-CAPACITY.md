# Capacity of moving players, and the dropped clients (PERF-CAPACITY)

The last loss of the scoreboard campaign ([SCOREBOARD.md](SCOREBOARD.md), "Where dbcraft loses" 1): with 200 players walking the SQL tick averaged 98.7 ms against vanilla's 81.5 ms, with 500 players
(sparse, all moving) 279 ms, crowded 446 ms, and the Rust gateway closed 70-240 of the 500 clients.  This document is the profile of that tick, what was changed, what the changes did, the cause of
the dropped clients, what did not work, and what is still a loss.  Every number says where it comes from; the machine was NOT quiet (see "Method"), so ratios between the two trees, measured
alternately in the same minutes, are the result, and absolute milliseconds are not comparable with the quiet-machine campaign.

## Result

(Filled in at the end of the document's work: see "Results".)

## Method

* **Two trees, alternated.**  The tree before this work (commit `d53eb24`, extracted to `.capbase/`, own PostgreSQL cluster in `/dev/shm/cap2`, own gateway binary) and this tree (own cluster in `/dev/shm/cap`) run the
  scoreboard's `pop` scenario one after the other, A B A B ... (`tools/scoreboard/cap_ab.sh`, which calls `tools/scoreboard/run.py` of each tree).  Same scripted clients (`loadgen.py`, view distance 10), same
  settings as the campaign (`tools/scoreboard/dbcraft.sh settings`: view and simulation distance 10, `dbcraft.chunk-generation = async`), Rust gateway, survival core, vanilla tracker, dynamics, containers all ON
  as shipped; `jit` off and `synchronous_commit` off as in the campaign's cluster.  Vanilla was NOT run again (nothing here changes vanilla and the machine is not quiet): the vanilla figures quoted are the
  campaign's.
* **CPU time, not wall time.**  `run.py` now records `tick_cpu_ms` (the on-CPU time of the backend that ran the ticks, from `/proc`, divided by the ticks of the window) and `gateway_cpu_ms` per tick, next to the wall
  time from `mc.server_tick_log`.  The machine has 4 vCPUs that other agents shared during all of this (load average 3 to 8 while the cells ran) and the load generator (2 Python processes at 200 players, 5 at
  500) shares them too: wall time inflates, CPU time inflates less but does inflate (a tick backend running beside five busy Python processes took about 1.5 times the CPU the same work took in the
  in-database bench below).  The A/B alternation is what the comparison rests on.
* **An in-database bench** (`tests/bench/capacity/`: `run.sh`, `ab.sh`, `world.sh`, `bench.sql`) runs the whole tick (inbox, `mc.server_tick`, `net.drain_outbox`) for N players that walk like the load generator
  (4.317 blocks/s, a new heading every 3-8 s, bounded), with keep-alive and teleport answers, per-tick on-CPU time from `/proc/self/schedstat`, the gateway's maintenance vacuum run beside it, statement and function
  profiles (`PROF=1`), plans (`PLANS=file`).  `K=k` makes every client send k position packets (and k - 1 client_tick_end) per tick, which is what a client does that runs ahead of a slow tick (see
  "The feedback loop"), `COALESCE=true` what the gateway forwards after `coalesce_positions`.  It is for finding and checking costs, not for the headline numbers.
* **Traps found while building the bench** (each one made an early profile wrong; they are in the bench's comments):
  `createdb -T` does not copy `ALTER DATABASE ... SET` (JIT came back on: a 200 ms plan for a 35-row statement); without the gateway's maintenance thread `mc.player` grows to 1,000 pages for 200 rows and every
  scan costs a millisecond more; `ibench.setup` resets the clock after the join trigger stamped the tracker start, so the tracker looked at nobody until the clock caught up; and players without
  `view_distance_req` have the vanilla default of 2, which makes the tracking range and the chunk squares 7 x 7 chunks instead of the 23 x 23 the scripted clients ask for (the first profiles measured a server a
  tenth the size).

## Step 1: the profile

The walking tick of 200 players, from the live harness (`tools/scoreboard/capprof_live.sh`, `pg_stat_statements` and `track_functions` on for a 40 s window of the real cell, tree before this work, per tick; the
tick was 102 ms, the clients sent 958 frames per tick):

| cost | ms per tick | what it was |
|---|---|---|
| `mc.apply_player_moves_general` | 23.4 | the slow path: a client that sends two position packets in a tick (it does when the tick takes more than 50 ms) fell off the fast path; temp table, window functions, `ANALYZE` of the temp table every tick |
| `net.stream_chunks` + `mc.deliver_ready_chunks` | 25 | 8.7 ms of it one `DELETE ... USING unnest(...)` that scanned the whole primary key index (1,527 buffer hits for 63 rows) because the planner believes a churned queue table holds one row |
| `mc.refresh_visibility_vis` | 17.8 | joins every online player with `net.conn` and computes a dozen columns for each of them, 200 times a tick, to look at the 20 that moved |
| `net.process_fast` | 14.8 | of which 5 ms the per-packet handler for `chunk_batch_received` (30 a tick, every client sends one for every chunk border it crosses) |
| `net.drain_outbox` + the gateway's own statements | 9 | |
| `mc.vis_move`, `vis_step`, survival, containers, keep-alive | 15 | |
| `mc.dyn_step` (random ticks) | 6.9 | not touched (another track) |

At 500 players (sparse, in the same harness) the same list reads: visibility 90 ms, chunk streaming 85 ms (1,236 wanted rows a tick, 15 us each), moves 22, input 19, vis_move 13, drain 23, pairing bundles
25 of the visibility's 90 (44 new pairs a tick at 0.58 ms each), dynamics 17.

**The feedback loop.**  A client sends one position packet and one `client_tick_end` every 50 ms whatever the server does.  A tick that takes T ms therefore finds T / 50 pairs per client, and all the per-packet
work (decoding, the slow movement path, the work queue) grows with it, and so does the distance walked per tick (chunk borders, pairs) which is the work the tick has to do.  With a base cost b per tick and a cost s per
client tick the tick settles at T = b / (1 - s / 50) if s < 50 and runs away otherwise.  The scoreboard's 500-player cells were in the runaway region (279-446 ms, and 809 ms in this session's first measurement of
the old tree), and the drops, the late joins and the 5 s chat round trips come from there.  Cutting s helps twice.

## Step 2: what was changed

Every change keeps the bytes a client receives; the proof is named with each.  All of it is SQL in place (the functions are listed in `sql/OVERRIDES.txt` where they already were) plus `sql/980`, plus one
gateway filter.

1. **Several position packets per tick stay on the fast path** (`sql/431`, `mc.apply_player_moves`).  The fast path was only taken when every connection sent exactly one position packet.  It now also takes
   (position, tick end) pairs: the last position of a connection is what the general version applies anyway, and the only rule an earlier packet can trigger (two positions without a tick end between them) is
   tested with one window over the position and tick-end frames; a violation or a malformed packet still goes to the general version.  23.4 -> 1.5 ms at 200 players.  `tests/sql/431` flavours 11-13 compare it
   with the general version (and that a missing separator still kicks).
2. **The gateway merges the pairs** (`gateway/src/gateway.rs`, `coalesce_positions`, setting `coalesce_moves`).  Several position packets of one play connection in one tick, each two separated by a
   `client_tick_end`, are given to the database as the last one: the database then does the work of a client that keeps up, whatever the tick length.  A connection that could be kicked for any of the three rules
   (length, NaN or infinity by the exponent bits, two positions in a row), or that sent a rotation-only or status-only frame, or a mixture of the two position kinds, is left alone.  `tests/sql/982` proves
   on the database side that `[P1 TE P2 TE P3]`, `[TE TE P3]` and `[P3]` leave the same player rows, `mc.visible`, output bytes, kicks and connection rows (60 players of seven classes, tracker on and off, plus a
   mutation check); the gateway's unit tests cover the selection and the finite checks.  It merged 184,200 frames in the 60 s of one 200-player cell.
3. **The movement update with the tracker reads and writes the movers only** (`sql/431`).  With `dbcraft.vanilla-tracker` nobody is broadcast from the movement step (`mc.vis_move` does it), but the statement
   built the new state of every online player to update the few hundred that moved.  `tests/sql/431` repeats the comparison with the general version with the tracker on (and detects a mutation of the
   statement).  The wide-row UPDATE itself, 15 us per mover for a 111-column row, is what is left (see "Not done").
4. **Visibility: the candidates of a dirty player come from the index** (`sql/909`, `mc.refresh_visibility_vis`; the old function stays as `mc.refresh_visibility_vis_scan`).  For each dirty player one probe
   of the partial index `(chunk_x, chunk_z) where conn_id is not null` for the targets in its own square and one for the viewers whose square can contain it; the exact rule is tested on those only.  The
   first attempt (the chunk squares around the cells the dirty players stand in) was slower at 200 players: with 20 occupied cells the squares cover 84 % of the world.  `tests/sql/981` compares the two functions on
   random states (150 players, crowds of 140 in 3 x 3 chunks, spectators, per-client view distances 2-12, teleports whose client is still waiting for its chunks, jumps): the same `mc.visible`, counts,
   packets per connection in order, player rows.
5. **Chunk streaming** (`sql/436`, `sql/791`, `sql/780`).  The wanted rows of all crossers are recorded with two statements instead of a call per connection (through arrays: with a cross join of
   `generate_series` inside, the planner estimated 10 million rows and scanned all of `mc.chunk` for the anti-join, 10 ms); the delivered rows are deleted by tuple id after a probe of the primary key each (the
   plan above); the forget packets are built without a function call per row; `net.trim_queues` also truncates `mc.chunk_wanted` when it is empty and has grown past `dbcraft.queue-trim-bytes` (a minute of
   walkers left a 13 MB index for an empty table).  `tests/sql/984` compares `net.stream_chunks` with the version before (pasted into the test) on random states with a backlog, existing and missing chunks and two
   players asking for the same missing chunk.
6. **`chunk_batch_received` in bulk** (`sql/430`, `net.process_fast`).  Answered with the keep-alives and teleport confirmations in the one statement; the value rule of `net.h_play` (the last one counts, NaN and
   tiny become 0.01, at most 64) is reproduced and `tests/sql/983` compares the result with the per-packet path on every column of 30 connections.
7. **The configuration keep-alive** (`sql/980`, the cause of the dropped clients): next section.

## The dropped clients

The campaign's drops were all `connection N dropped: read timeout (no bytes)` in the gateway log, 70-240 of 500, and 82-132 of 500 even with 20 % moving (so not a movement effect).  Their join times were 22 s
(median) to 35 s.  The chain, read from the code and then reproduced:

1. `net.join_gate` parks a login for up to `dbcraft.join-max-wait-s` (20 s): the client sent its hello at second 0 and nothing since.
2. Released, it logs in, answers `select_known_packs`, and sends `finish_configuration`, its last bytes.  The server holds that packet back under the join entry budget (`dbcraft.join-entry-budget-ms`, 10 ms of
   entries per tick, three forced per tick after 20 s): at 500 joins with ticks of 300-800 ms, entries come at 3-5 a tick.  The client now waits for the `login` packet, **silent, in a state in which the server
   sent nothing either**.
3. After 30 s without a byte the gateway closes the connection (vanilla's `ReadTimeoutHandler(30)`, and a real client would have given up on its own at the same time: its own timeout counts the bytes it
   receives).  20 s of queue plus 30 s of silence is the 50-60 s mark where "about 100 of them" went in the campaign.

Vanilla never has that silence: its configuration listener is the same class as its play listener and sends a keep-alive 15 s after it started and every 15 s after the answer
(`ServerCommonPacketListenerImpl.keepConnectionAlive`), which the client answers in the configuration state.  dbcraft sent keep-alives in the play state only.  `sql/980` adds the configuration one: a
connection that has been silent for 15 s in the configuration state (since it connected or since the last answer) gets a `keep_alive` with the clock in ms as its id, once a second at most; the answer clears
it; no answer for 30 s is `disconnect.timeout`.  A join that takes less than 15 s in that state is untouched.  `tests/gateway/config_keepalive.py` is the end-to-end proof: a client sits in the configuration
state for 40 s answering only keep-alives.  **Tree before: closed by the gateway after 30.8 s** (`dropped: read timeout (no bytes)`); **this tree: keep-alives answered at 15.2 s and 30.1 s, still connected,
play entered when it finally sent `finish_configuration`.**  The tests of the SQL side are `tests/sql/980`.

Other things that were looked at and are NOT the cause: the gateway is one thread and does not read while a tick runs, but it reads every socket once per loop pass, before each tick, and a client's bytes wait
in the kernel buffer for at most one tick (1 KB of a client's traffic per 50 ms; an 800 ms tick queues 16 packets), so no byte is lost and nothing looks silent; a reader thread would not change the drops.  The
write queue (8 MB per connection) was never the reason in any log.  The gateway's drop line now says how long ago the connection was accepted, how many bytes and frames it had sent, how many seconds ago the
last byte came, whether it was in play and how much was queued to it, so the next one can be read off the log.

## Not done, and what did not work

(Filled in below with the results.)

## Reproduce

```
tools/scoreboard/cenv_capacity COMMAND          # like cenv, ports and directory from CAP_DIR (default /dev/shm/cap) and CAP_PORT (56211)
tests/e2e/setup.sh                              # the database (with DBCRAFT_PGDATA / DBCRAFT_PGPORT of that cluster), gateway/build.sh first
tools/scoreboard/cap_ab.sh 3 out.txt -- pop --n 200 --moving 1.0 --bound 500 --hold 60       # A/B against the tree in .capbase (git archive of the commit before)
SCORE_PROFILE_CMD="tools/scoreboard/cenv_capacity tools/scoreboard/capprof_live.sh 40 0" tools/scoreboard/cenv_capacity python3 tools/scoreboard/run.py pop --n 200 --moving 1.0 --bound 500 --servers dbcraft
DBCRAFT_PGPORT=.. DBCRAFT_BENCH_DB=.. tests/bench/capacity/world.sh 70;  K=2 COALESCE=true PROF=1 tests/bench/capacity/run.sh 500 100 1.0 120 label
```
