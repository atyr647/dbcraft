# Capacity of moving players, and the dropped clients (PERF-CAPACITY)

The last loss of the scoreboard campaign ([SCOREBOARD.md](SCOREBOARD.md), "Where dbcraft loses" 1): with 200 players walking the SQL tick averaged 98.7 ms against vanilla's 81.5 ms, with 500 players
(sparse, all moving) 279 ms, crowded 446 ms, and the Rust gateway closed 70-240 of the 500 clients.  This document is the profile of that tick, what was changed, what the changes did, the cause of
the dropped clients, what did not work, and what is still a loss.  Every number says where it comes from.  **The machine was not quiet for most of it** (other agents; see "Method"), so the
results are ratios of two trees measured alternately in the same minutes, and the absolute milliseconds are not comparable with the quiet-machine campaign; the few cells run on a quiet machine
say so.

## Result

**Targets and where they ended** (CPU = on-CPU time of the tick backend per tick, from `/proc`; wall = `mc.server_tick_log`; the harness is the scoreboard's `pop` scenario, scripted clients, Rust gateway,
survival core, vanilla tracker, dynamics, containers all ON as shipped, view distance 10):

| Target | Result |
|---|---|
| 200 walking players, tick mean <= 70 ms, chat p50 <= vanilla's | **met**: 63.5 / 58.1 ms wall, 58.3 / 54.0 ms CPU, chat p50 91 / 63 ms (vanilla 10,000 = the probe's cap, no reply).  With `dbcraft.dynamics = off` (quiet machine): 41.5 ms wall, 47.4 CPU |
| 500 sparse all moving, <= 100 ms mean CPU-time tick | **not met**: 130.6 / 143.0 ms wall, 141.4 / 155.2 ms CPU on a quiet machine (load 1.1-1.3), 155 / 209 ms wall with the machine shared (load 4-5); dynamics off: 121.9 wall, 132.2 CPU.  The tree before: 444-769 ms wall, so 2.1-5.9 times better |
| zero dropped clients in the 500-player runs | **met**: 0 of 500 in all 6 runs of the final tree (4 sparse, 2 crowded; and in 2 sparse runs of its first version, which lost 5 clients in a crowded one); the tree before dropped 29 and 34 of 500 in 2 of its 6 sparse runs here (70-240 in the campaign) |
| crowded 500 (30 x 30 chunks) as low as possible | 778 / 884 ms wall (794 / 890 CPU), 0 dropped; the tree before 1,317 and 1,500-1,767 ms.  Vanilla in the campaign: 135 ms.  **Still a big loss** |

**Before and after, same harness, alternated runs** (A = tree before this work, B = this tree; wall ms of the SQL tick unless marked; ranges are the runs; vanilla = campaign figures, quiet machine, NOT re-run):

| Scenario | campaign tree (`d53eb24`, this session, loaded machine) | feature branch without this work (`0180959`) | **this tree** | vanilla (campaign) |
|---|---|---|---|---|
| 50 players walking: tick mean | 54.6 / 56.4 (CPU 58 / 60), chat p50 97 / 106 | 34.4 / 36.0 (CPU 38 / 40), chat p50 40 / 40 | **31.0 / 30.8** (CPU 34.8 / 34.9), chat p50 43 / 41 | 61.6, chat p50 51 |
| 200 walking: tick mean | 106.5 / 97.8 / 116.3 (CPU 107 / 101 / 118), chat p50 212 / 146 / 295 | 66.9 (load 2.0) / 152.5 (load 4.8); CPU 75 / 139 | **63.5 / 58.1** (CPU 58 / 54), chat p50 91 / 63 | 81.5, chat p50 10,000 |
| 500 sparse all moving: tick mean | 444 / 535 / 769 / 449 (CPU 447 / 548 / 672 / 467), dropped 0 / 29 / 0 / 0 | 558 / 631 (CPU 539 / 501), dropped 0 / 34 | **155 / 209** (CPU 162 / 176, loaded); **131 / 143 / 138** (CPU 141 / 155 / 150, quiet); dropped 0 | not run (crowded only) |
| 500 crowded all moving: tick mean | 1,501 / 1,767 (CPU 1,560 / 1,676), dropped 0 | 1,317 (CPU 1,308), dropped 0 | **884 / 778** (CPU 890 / 794), dropped 0 | 135, dropped 0 |

The middle column exists because other tracks merged into the feature branch during this work (dynamics: the random-tick list maintenance that took the 50-player tick from 47 to 34 ms; the storm track's locator-bar
packets); the last column of ratios is this work's own: 200 walking 66.9 / 152.5 -> 63.5 / 58.1, 500 sparse 558 / 631 -> 155 / 209 (-- and 131-143 quiet), 500 crowded 1,317 -> 778-884.  Under a quiet machine the tree
before is much less bad at 200 players (66.9 against this tree's 63.5): **the tree before has a feedback loop (below) that makes it fall off a cliff when the machine is shared, this tree does not.**
The same alternating harness measured the 200 players twice at load 2 and 5: before 67 -> 152 ms, now 63 -> 58.

## Method

* **Two trees, alternated.**  The tree before (extracted with `git archive` to `.capbase/` (the campaign commit) or `.capbase2/` (the feature branch just before this work), own PostgreSQL cluster in `/dev/shm/cap2`
  or `cap3`, own gateway binary) and this tree (own cluster in `/dev/shm/cap`) run the scoreboard's `pop` scenario one after the other, A B A B ... (`tools/scoreboard/cap_ab.sh`, which calls
  `tools/scoreboard/run.py` of each tree).  Same scripted clients (`loadgen.py`, view distance 10) and settings as the campaign (`tools/scoreboard/dbcraft.sh settings`: view and simulation distance 10,
  `dbcraft.chunk-generation = async`), `jit` off and `synchronous_commit` off as in the campaign's cluster.  Vanilla was not run again: nothing here changes vanilla and the machine was not quiet.
* **CPU time, not only wall time.**  `run.py` now records `tick_cpu_ms` (the on-CPU time of the backend that ran the ticks, from `/proc`, divided by the ticks of the window) and `gateway_cpu_ms` per tick, next to
  the wall time from `mc.server_tick_log`.  The machine has 4 vCPUs that other agents shared (load average 1 to 8 while the cells ran; each cell says its load) and the load generator (2 Python processes at 200
  players, 5 at 500) shares them too.  Wall time inflates; CPU time inflates less but does inflate (the same work took about 1.5 times the CPU beside five busy Python processes as in the in-database bench below).
* **An in-database bench** (`tests/bench/capacity/`: `run.sh`, `ab.sh`, `world.sh`, `bench.sql`) runs the whole tick (inbox, `mc.server_tick`, `net.drain_outbox`) for N players that walk like the load generator
  (4.317 blocks/s, a new heading every 3-8 s, bounded), with keep-alive and teleport answers, per-tick on-CPU time from `/proc/self/schedstat`, the gateway's maintenance vacuum beside it, statement and function
  profiles (`PROF=1`), plans (`PLANS=file`).  `K=k` makes every client send k position packets (and k - 1 client_tick_end) per tick, which is what a client does that runs ahead of a slow tick (see
  "The feedback loop"), `COALESCE=true` what the gateway forwards after `coalesce_positions`.  It is for finding and checking costs, not for the headline numbers (the real harness costs about 1.5 times more CPU).
* **Traps found while building the bench** (each one made an early profile wrong; they are in the bench's comments):
  `createdb -T` does not copy `ALTER DATABASE ... SET` (JIT came back on: a 200 ms plan for a 35-row statement); without the gateway's maintenance thread `mc.player` grows to 1,000 pages for 200 rows and every
  scan costs a millisecond more; `ibench.setup` resets the clock after the join trigger stamped the tracker start, so the tracker looked at nobody until the clock caught up; and players without
  `view_distance_req` have the vanilla default of 2, which makes the tracking range and the chunk squares 7 x 7 chunks instead of the 23 x 23 the scripted clients ask for (the first profiles measured a server a
  tenth the size, and the first A/B of the visibility change was run on it).

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

At 500 players (sparse) in the same harness: visibility 90 ms, chunk streaming 85 ms (1,236 wanted rows a tick, 15 us each), moves 22, input 19, vis_move 13, drain 23, of the visibility's 90 the pairing
bundles 25 (44 new pairs a tick at 0.58 ms each), dynamics 17.  And one thing the in-database benches had hidden: **at 50 to 120 players the locator bar (`mc.vis_wp_pass`, every pair of players every tick) was
half the tick** (50 walkers: 23 of 47 ms; 120 walkers 62 ms, and 121 players walking 26 ms because the bar is switched off above 120: `dbcraft.locator-bar-max-players`).

**The feedback loop.**  A client sends one position packet and one `client_tick_end` every 50 ms whatever the server does.  A tick that takes T ms therefore finds T / 50 pairs per client, and all the per-packet
work (decoding, the slow movement path, the work queue) grows with it, and so does the distance walked per tick (chunk borders, pairs) which is the work the tick has to do.  With a base cost b per tick and a cost s per
client tick the tick settles at T = b / (1 - s / 50) if s < 50 and runs away otherwise.  The scoreboard's 500-player cells were in the runaway region (279-446 ms, and 444-769 ms in this session's runs of the
old tree: the same cell, the same tree, 1.7 times apart), and the drops, the late joins and the 1-3 s chat round trips come from there.  Cutting s helps twice: the bench measures b = 70 and s = 18 ms for 500 walkers
now (k = 1: 85 ms, k = 2: 108, k = 3: 120, k = 6: 180), against a slope above 50 before.

## Step 2: what was changed

Every change keeps the bytes a client receives; the proof is named with each.  All of it is SQL in place (the functions are listed in `sql/OVERRIDES.txt` where they already were) plus `sql/980`, `sql/981`, and one
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
   of the partial index `(chunk_x, chunk_z) where conn_id is not null` for the targets in its own square and one for the viewers whose square can contain it; the exact rule is tested on those only; the new pairs
   are probed in `mc.visible` before they are inserted (a crowd tries 175,000 a tick and nearly all exist).  The first attempt (the chunk squares around the cells the dirty players stand in) was slower at 200
   players: with 20 occupied cells the squares cover 84 % of the world.  `tests/sql/981` compares the two functions on random states (150 players, crowds of 140 in 3 x 3 chunks, spectators, per-client view
   distances 2-12, teleports whose client is still waiting for its chunks, jumps): the same `mc.visible`, counts, packets per connection in order, player rows.
5. **Chunk streaming** (`sql/436`, `sql/791`, `sql/780`).  The wanted rows of all crossers are recorded with two statements instead of a call per connection (through arrays: with a cross join of
   `generate_series` inside, the planner estimated 10 million rows and scanned all of `mc.chunk` for the anti-join, 10 ms); the delivered rows are deleted by tuple id after a probe of the primary key each (the
   plan above); the forget packets are built without a function call per row; `net.trim_queues` also truncates `mc.chunk_wanted` when it is empty and has grown past `dbcraft.queue-trim-bytes` (a minute of
   walkers left a 13 MB index for an empty table).  `tests/sql/984` compares `net.stream_chunks` with the version before (pasted into the test) on random states with a backlog, existing and missing chunks and two
   players asking for the same missing chunk.
6. **`chunk_batch_received` in bulk** (`sql/430`, `net.process_fast`).  Answered with the keep-alives and teleport confirmations in the one statement; the value rule of `net.h_play` (the last one counts, NaN and
   tiny become 0.01, at most 64) is reproduced and `tests/sql/983` compares the result with the per-packet path on every column of 30 connections.
7. **The locator bar pass streams its pairs** (`sql/908`: `pr` and `dc` are no longer `MATERIALIZED`, two words): 100 walkers 79 -> 48-58 ms of tick CPU, 50 walkers 39 -> 30 (bench).  Same statement, same rows.
8. **The attribute memo** (`sql/981`, `sql/903`): the `update_attributes` entries of a pairing bundle of a player that wears and holds nothing depend on three values and are kept per combination
   (`mc.attr_memo`, filled by the first caller; `truncate mc.attr_memo` after reloading the attribute reference data); 0.17-0.28 ms a bundle, 44 bundles a tick at 500 walkers, 433 in a crowd.  `tests/sql/985`
   compares it with `mc.pairing_attrs` and checks that a player with a helmet does not use it.
9. **The configuration keep-alive** (`sql/980`, the cause of the dropped clients): next section.

In the in-database bench (500 walkers, view distance 10, two client ticks per tick, tracker, survival, dynamics on) the tree before took 139-154 ms of CPU a tick and this tree 88-114 (the gateway's merge, step
2, is a further -35 % at that load: 121-124 -> 73-83 in the first, view-distance-2 version of the bench).  The real harness at 500 walkers does not come out at the bench's figure: its CPU is 1.5 times higher
with the load generator beside it and its k is higher (T / 50).

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
connection that has been silent for 10 s in the configuration state (since it connected or since the last answer) gets a `keep_alive` with the clock in ms as its id, looked for by the wall clock once a second;
the answer clears it; no answer for 30 s is `disconnect.timeout`.  A join that takes less than 10 s in that state is untouched.  `tests/gateway/config_keepalive.py` is the end-to-end proof: a client sits in the
configuration state for 40 s answering only keep-alives.  **Tree before: closed by the gateway after 30.8 s** (`dropped: read timeout (no bytes)`); **this tree: keep-alives answered at 10.3, 20.4 and 30.6 s, still connected, play entered when it finally sent `finish_configuration`.**  The SQL side is `tests/sql/980`.

**The first version of the fix was not enough, and the gateway's new log line showed why.**  It looked once every 20 ticks and waited 15 s.  At the 700 ms ticks of a crowded 500-player storm one look is 14 s
apart, so a connection whose last byte was 29 s old was sent its keep-alive too late: five of the last joiners were closed (`31 s after connecting, 65 bytes and 6 frames read in all, last byte 30 s ago, in
play: true`).  It now looks by the wall clock at most once a second and sends after 10 s of silence; the next 6 runs of 500 players (4 sparse, 2 crowded) lost nobody.

Other things that were looked at and are NOT the cause: the gateway is one thread and does not read while a tick runs, but it reads every socket once per loop pass, before each tick, and a client's bytes wait
in the kernel buffer for at most one tick (1 KB of a client's traffic per 50 ms; an 800 ms tick queues 16 packets), so no byte is lost and nothing looks silent; a reader thread would not change the drops.  The
write queue (8 MB per connection) was never the reason in any log.  The gateway's drop line now says how long ago the connection was accepted, how many bytes and frames it had sent, how many seconds ago the
last byte came, whether it was in play and how much was queued to it, so the next one can be read off the log.

## Not done, and what did not work

* **Did not work: the first neighbourhood query for visibility** (chunk squares around the occupied cells of the dirty players): 8.7 ms against the scan's 5.8 at 200 players, because 20 cells' squares cover 84 %
  of the world.  Replaced by per-player probes (21 -> 4 ms at 500).
* **Did not work: one `want_chunks` statement with the cross join inside** (10 ms: the planner's 10 million row estimate, a hash anti-join over all of `mc.chunk`): arrays first, then the statements.
* **Did not work: `plan_cache_mode = force_generic_plan` on the locator-bar pass**: planning 5.9 -> 0.5 ms and execution 18.5 -> 25.3, no gain.
* **Not done: a reader thread in the gateway.**  It would not change a drop (above) and costs a thread-per-connection or a shared read queue for no measured gain.
* **Not done: a narrow position table.**  A mover's UPDATE of the 111-column `mc.player` row costs 15 us (7.5-12 ms of 500 movers' tick); the columns are read in hundreds of places and `mc.player` is the
  entity table of every other track.
* **Not done: streaming chunks without `mc.chunk_wanted`** (delivering what exists in the tick that wants it and storing only the rest).  It would save the 663 inserts (8 ms) and part of the 8.7 ms
  `chunk_wanted_view` clean-up at 500 walkers, but with the tick spending more than 24 ms the global cap of `dbcraft.chunk-budget-per-tick` shrinks to 240 chunks a tick and most wanted rows do wait: the
  rows are needed in exactly the regime this work is about.
* **Done later (docs/PERF-LOCATOR.md): the locator bar's pass is dirty-driven and the cap of 120 is gone** (default 100,000, 45-70 % of the old pass cost, not the +3 ms target).  The paragraph that stood here ("not done") described the all-pairs pass.
  **Update (docs/PERF-STORM.md, round 3):** the rows are now one row per connection, a cursor over the precomputed spiral of its square (`sql/930`), when every chunk of the strip exists: at 35 crossings a tick (a backlog) 5,810 -> 3,283 wanted rows and 73 -> 62-69 ms a tick in the in-database bench, under the budget
  no gain beyond the removed inserts and deletes (12-20 against 18-23 ms a tick).
* **Not done: the locator bar at more than 120 players, and its pass dirty-driven.**  Up to 120 players the bar is half of a walking tick (the pass is every pair, every tick); the cap of 120 makes the 121st
  walker make the tick cheaper by 60 ms.  Skipping the pairs where neither side changed block or chunk is possible for block and chunk connections and not for azimuth ones; it needs its own differential test.
* **Not done: a per-chunk fan-out for the tracker's movement packets** (the crowd).  `mc.vis_move` joins the movers' packets with `mc.visible` per pair: 44,000 rows a tick in a crowd of 500 (69 ms at one client tick
  per tick); viewers in the same chunk do not have the same targets under the exact circle rule.
* **Not done: dynamics** (another track): `dbcraft.dynamics = off` takes 500 sparse walkers from 130.6 / 143.0 to 121.9 ms wall and 200 from 58 to 41.5 ms.

## Still a loss

* **500 sparse walkers: 131-143 ms on a quiet machine, 155-209 shared; target 100 CPU not met** (141-155 ms CPU quiet, 132 with dynamics off).  Vanilla was not measured in this cell.  The tick is one transaction
  on one core with a base cost of about 65 ms (the scans of 500 rows, the tracker, 28 ms of dynamics before the dynamics track's own fixes) and about 18 ms for every client tick of walking per tick (chunk rows, pairs), so
  it settles near 110 ms in the bench and 130-150 with the load generator beside it.
* **500 crowded: 778-890 ms against vanilla's 135.**  Everybody sees 175 others: a tick with all 500 dirty is 175,000 pair tests, 5,000 chunk rows and 44,000 packet rows.
* **50 walkers' chat p50: 41-43 ms against vanilla's 51** is now a win on the same machine for the first time, but the margin is the dynamics track's, not this one's; at 100 walkers the locator bar makes the tick 48-58 ms.

* **Update, docs/PERF-VIS2.md (2026-11-05):** the visibility refresh of the crowded cell tests only the pairs near the edge of the circle (183 -> 35 ms of the phase, live; same pairs and packets, proved on random walks) and the
  500 sparse cell was profiled again on this tree: tick 58-62 ms, tick CPU 63-65 ms (the 100 ms target is met there; the table above is from before), chunk streaming 19 ms the largest part.

## Reproduce

```
tools/scoreboard/cenv_capacity COMMAND          # like cenv, ports and directory from CAP_DIR (default /dev/shm/cap) and CAP_PORT (56211)
tests/e2e/setup.sh                              # the database (with DBCRAFT_PGDATA / DBCRAFT_PGPORT of that cluster), gateway/build.sh first
env BASE_TREE=$PWD/.capbase2 CAP_DIR_A=/dev/shm/cap3 CAP_PORT_A=56241 tools/scoreboard/cap_ab.sh 3 out.txt -- pop --n 200 --moving 1.0 --bound 500 --hold 60       # A/B against a tree in a directory (git archive of a commit)
SCORE_PROFILE_CMD="tools/scoreboard/cenv_capacity tools/scoreboard/capprof_live.sh 40 0" tools/scoreboard/cenv_capacity python3 tools/scoreboard/run.py pop --n 200 --moving 1.0 --bound 500 --servers dbcraft
DBCRAFT_PGPORT=.. DBCRAFT_BENCH_DB=.. tests/bench/capacity/world.sh 70;  K=2 COALESCE=true PROF=1 tests/bench/capacity/run.sh 500 100 1.0 120 label
python3 tests/gateway/config_keepalive.py --port PORT --wait 40       # against a running gateway: the configuration keep-alive end to end
```
Tests added: `tests/sql/431` (flavours 11-13 and the tracker pass), `980`-`985`; gateway unit tests of `coalesce_positions`.  Checks run on the final tree: `tests/sql/prun.sh` 80 of 80 files, 3,159 checks
(own cluster; `970_quiet_gate` needs a cluster that no other test is writing to, as before), `tools/check_overrides.py`, `tools/check_inlining.sh`, `tools/check_fresh_migration.sh`, `gateway/build.sh test` (62 gateway
tests), `tests/gateway/run_e2e_rust.sh` (all comparisons with the vanilla recordings passed), `tests/e2e/run_all.sh` (passed; the fill, commands and visibility recordings did not exist, the visibility ones were
recorded fresh and compared: same differing steps before and after this work, see docs/PLAYER-VISIBILITY.md).  The raw lines of the runs quoted here are in `docs/perf-capacity-results.txt`.
