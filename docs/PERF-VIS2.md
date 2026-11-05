# Who sees whom, driven by the boundary of the circle (PERF-VIS2)

The live profile of 500 players in 30 x 30 chunks ([perf-crowd-live-profile-2026-11-05.txt](perf-crowd-live-profile-2026-11-05.txt)) put 63 % of the tick into `mc.refresh_visibility_vis`: about 137 dirty players
a tick, each tested against nearly everybody, 137,000 pair tests and 46,000 probes of `mc.visible`, to find the few hundred pairs that change.  This document is the cause, the change (the same pairs, the same
packets in the same order, proved on random walks), the numbers before and after, the profile of the other cell that was a loss (500 players spread over 100 x 100 chunks) and what did not work.
All of it is in `sql/909` (the function), `tests/sql/990` (the proof), `tests/bench/game/` (the benches) and one small edit in `sql/791`.

**The machine was shared for every measurement here** (four cores, other agents: load average 2 to 6).  Wall time inflates by up to 1.7 times between two runs a few minutes apart, so every number that
is compared with another comes from runs next to each other (A B A B) and the ratios are what to read; the absolute milliseconds are not those of a quiet machine.

## Result

| | before (neighbourhood version) | after (boundary version) | ratio |
|---|---|---|---|
| **live harness, 500 crowded walkers** (scripted clients, Rust gateway, 40 s window, load 3-5): visibility phase | **183.5 ms** | **35.2 ms** | **5.2** |
| ... mean tick of the window / CPU of the tick backend per tick (run.py) | 284 ms / 321 ms | 130 ms / 139 ms | 2.2 / 2.3 |
| walking bench, crowd 30 x 30 chunks, 0.215 blocks per tick: visibility phase (4 runs each, quiet 2-3 load / shared 5.6) | 36.2 34.6 33.3 32.1 / 50.4 43.9 | 13.1 13.1 12.2 11.8 / 14.1 17.6 | 2.5 - 3.6 |
| walking bench, crowd, 1.1 blocks per tick (a 250 ms tick): visibility phase | 159.2 157.4 160.3 153.7 / 216.6 219.9 | 42.6 43.4 42.3 41.7 / 61.6 61.7 | 3.5 - 3.7 |
| walking bench, the final function, load 5.7-6.6 (everything about 2 times slower): crowd 0.215 / 1.1 | 63.6 / 244.3 | 22.6 / 65.8 | 2.8 / 3.7 |
| walking bench, the same 30 x 30 chunks, 250 / 500 / 1000 players, 0.215 (load 5.2-6.5) | 17.9 / 63.6 / 197.0 | 6.7 / 22.6 / 42.7 | 2.7 / 2.8 / 4.6 |
| walking bench, 500 sparse (100 x 100 chunks), 0.215 / 1.1 | 9.8 / 47.2 | 11.7 / 27.5 | 0.8 / 1.7 |
| live harness, 500 sparse walkers: visibility phase / mean tick / tick CPU | 17.0 ms / 81 ms / 71 ms (load 3.6-5.3) | 10.0 and 9.4 ms / 62 and 58 ms / 65 and 63 ms (load 1.9 and 3.6) | |

**The target of 5 times in the walking bench was not reached: 2.5-3.6 times at 0.215 blocks a tick and 3.5-3.7 at 1.1.**  The live harness, where a slow tick makes the walkers cover more ground per tick (the
feedback loop of the profile), shows the 5.2.  What is left is in "Where the rest goes" below: it is the work for the pairs that really change (the pairing bundles, 12 ms of the 42 at 1.1), the
pair loop (about 0.1 us per pair, dirty x online) and a floor of about 5 ms a tick that has nothing to do with how many pairs there are.  The raw lines of every run are in
[perf-vis2-results.txt](perf-vis2-results.txt) and `perf-vis2-live-*.txt`.

## Where the time went (before)

The three statements of the old function in the live crowd profile (ms per tick; 137 dirty players, 27,000 directed pairs in range of a dirty one, 190 pairs that change):

| statement | ms | what it does | why it costs that |
|---|---|---|---|
| `dpc` (candidate search) | 82.6 (64.7 in the first profile) | tests every dirty player against everybody in its chunk square | 137,000 pair tests of wide `mc.player` rows through a lateral index probe, the rule with `^ 2` (a `pow` call each) in both branches: 0.5 us a pair |
| `insert into mc.visible` | 68.6 (57.3) | `NOT EXISTS` probe of every pair in range, then insert, then the pairing bundles | not the insert, not index maintenance, not WAL, not a trigger, not the width of the row (`mc.visible` is `UNLOGGED`, 14 bytes, two indexes, no triggers, 190 rows go in).  `EXPLAIN (ANALYZE, BUFFERS)`: the planner anti-joins the 27,000 in-range pairs (sorted) against **a full ordered scan of the primary key, 62,000 index-only entries with 62,000 heap fetches, 31,000 buffer hits, for 588 inserted rows**.  A probe of the primary key costs 1.0-1.1 us (measured on its own), so 46,000 of them are 50 ms whichever way they are done, plus 12 ms for the 180 pairing bundles |
| `delete from mc.visible` | 27.3 (20.1) | every row of a dirty player (`viewer = any(d) or target = any(d)`) not in the in-range set | `EXPLAIN`: a merge anti join of **the whole primary key index (62,000 entries, 34,000 removed by the filter, 31,800 buffer hits) with the sorted in-range set (27,000 rows) for 604 deleted rows** |

So the insert and delete statements cost O(rows of `mc.visible` + pairs in range), not O(changes): the number of dirty players times the number in range, which in a crowd is everybody.
The candidate search is O(dirty x online) with a constant 5 times too large.

## The change

### Idea: a pair can only change near the edge of the circle

`mc.refresh_visibility_vis_nb` (the old function, kept as the reference) re-evaluates every pair of a dirty player.  A pair (v, t) can only change from "in range" to "out" or the other way if the
distance between the two has changed by more than its distance from the radius of the viewer, R(v) = min(tracking range, view distance x 16).  How far it can have changed is known from two things the table
already keeps: where each player was when its pairs were last evaluated (`vis_x`, `vis_z`, sql/909) and the rule that makes a player dirty (4 blocks from there, or a chunk border, `mc.apply_player_moves`).

### The bound, and why the output is identical

Notation: `b(P)` = (vis_x, vis_z) of P, `pos(P)` = where P is now, `disp(P) = |pos(P) - b(P)|`.

1. The function with the old rule changes a pair only on a tick where one of its players is dirty (that is the old behaviour and it stays), and then it sets the status of the pair to the rule applied to the
   current positions.  So the stored status of a pair is the rule at **tau(pair) = the last tick on which either player was dirty** (or the pair's creation).  By induction over the ticks the
   boundary version has the same stored state as the old one; it remains to show that for a pair with a dirty player that it does not look at, the rule now gives the stored status.
2. On tick tau one of the two players, E, was evaluated: its pairs were evaluated at its current position, which became `b(E)` (the update at the end of the function), and it has not been evaluated since,
   so `b(E)` is still its baseline.  The other, N, was not dirty then, so it was less than 4 blocks from `b(N)` (the dirty rule), and `b(N)` is still its baseline too (not evaluated since either).
   (If both were dirty, both stood on their baselines: even better.)
3. Since tau the distance between the two has therefore changed by at most `disp(E) + (disp(N) + 4)` <= `disp(a) + disp(b) + 4`.  A pair whose current distance d satisfies
   `|d - R| > disp(a) + disp(b) + 4` was on the same side of R at tau: its status cannot have changed.  The function looks only at the pairs with `|d - R| <= m`, `m = k(a) + k(b)`, `k(P) = disp(P) + 2.005`
   (the 0.01 is rounding), tests them with the exact old rule (the same expression, so the same floating point result at the edge), probes `mc.visible` once for each and writes only the differences.
4. **Who has no such bound is tested against everybody**, as before (k = infinity): a player that has never been evaluated *in this session* (a join, a respawn: `vis_eid` is the entity id of
   the session, a new session of the same row has a new one); whose radius (`vis_rng`) or spectator state (`vis_spec`) differs from the ones its pairs were evaluated with (a changed view distance, a changed game
   mode, a changed `view-distance` property: then step 2 does not hold for it); a teleported player whose client still waits for its chunks (its pairs were evaluated at positions that are not its
   `vis_x`; it is also the old rule's `stale`, kept exactly: adds suppressed, no deletes); a player that is 4 blocks from its baseline without being dirty (cannot happen through the movement step, but then
   step 2 is false); **a dead player** (sql/836 deletes the pairs of a corpse 19 ticks after the death, behind this function's back, and the old function brings them back when somebody near it is dirty: a
   quirk that has to be kept to have the same output); **a dirty player whose chunk before the move is unknown** (`vis_ocx` is null: sql/468's marker for a player made dirty by anything but the movement step: join,
   respawn, view distance change, game mode re-check, teleport; the respawn in sql/836 deletes all pairs of the player, `tests/sql/830` found that when the first version did not know about it); and every dirty player
   that jumped far has a disp that makes its ring cover everybody (a bound over 14 blocks is infinite).  The state is three columns of `mc.player` written by the update that already clears `vis_dirty` (no extra write in the normal case).
   A player without a bound that is **not** evaluated itself (a waiting client, a radius or game mode that changed without marking it, a dead player) has its pairs evaluated by the dirty players with what it
   is now; so that it cannot look trustworthy again if what it is now changes back before it is evaluated (view distance 10, 8, 10), `vis_eid` is set to null at that point and it stays without a bound until
   it is evaluated.  (Found by the test with game modes changed behind the trigger of sql/900; the same for a view distance property edited twice.)
5. The chunk-square test of the old code is kept in the exact rule (it is implied by the circle for consistent chunk coordinates; the proof assumes `chunk_x = floor(x / 16)` as the server writes it).

What is **not** covered: a pair state changed by code that neither marks a player nor is one of the cases above.  Today that is nothing in the tree (the writers of `mc.visible` are the refresh functions,
`mc.on_leave`, and sql/836 for deaths and respawns); an administrator who deletes rows of `mc.visible` by hand gets the old function's behaviour (pairs come back when a player of them is dirty) only for pairs
near the edge: `mc.refresh_visibility_vis_nb` is the one to run after such a repair, once, with all players marked dirty.

### Proof by test: `tests/sql/990_vis_boundary.sql`

Random walks, every tick compared with `mc.refresh_visibility_vis_nb` (which `tests/sql/981` already compares with the scan version of before): the old function runs first in a rolled back sub-transaction,
then the new one for real; the pairs of `mc.visible`, the packets per connection in order (md5 over the bytes), the counts and the columns of the player rows that the refresh writes must be equal on
**every** tick.  The world is moved the way the server moves it: walkers (dirty by the same rule as `mc.apply_player_moves`), idle players, jittering walkers, teleports (half of them a few blocks, half
across the world) whose client keeps its old view for a while (stale viewers), view distance changes, game mode changes through the real trigger, leaves and joins (a new session of the same row, through the real
join trigger), deaths whose corpses are removed behind the function's back and respawns as sql/836 does them, the `view-distance` property edited under the players, game modes changed without the trigger's mark.  910 ticks, 26,000 dirty-player evaluations, 95,000 pairs added, 48,000 removed, 38,000 packet rows; 210-300 players in the long cases (crowd of 210 in 10 x 10 chunks, 220 players with view
distances 2 to 32 and everything at once, 200 players over 100 x 100 chunks, 100-110 ticks each), 8 more random worlds.  **Mutation check**: nine mutations of the new function (no slack for the player
that was not evaluated, a client that waited for its chunks keeps its evaluation, the radius rule dropped, the session rule dropped, the game mode rule dropped, the bound ignoring how far the players moved, a dead
player trusted, an unknown chunk before the move trusted, a player without a bound looking trustworthy again after its game mode changed back) are each shown to make the comparison fail; four of them needed
scenarios made for them (jittering walkers; teleports of a few blocks; changes that bypass the marks), the first version of the test did not notice them.  About 5 minutes (3 minutes of it the comparisons).

### What else changed in the function

* The candidates come from one scan of the online players into a narrow CTE (`pc`: the columns of the pair loop first); the loop is `dirty x online` with `abs(sqrt(dx^2 + dz^2) - R) <= k(a) + k(b)` (the squares as
  products: `^ 2` is a call of `pow`; the sqrt form measured 1.25 times faster than the algebraic one and 2.2 times faster than the first version), a pair of two dirty players once; 0.1 us a pair.
* The stored state of a candidate is read by **a probe of the primary key** (a scalar subquery in a materialized CTE).  As a join the planner turns it into a hash join over all of `mc.visible`
  (25 ms) or a merge join over the whole index.
* **Deletes by tuple id** (the probe returns `ctid`): 30 ms (auto_explain, with timing) with the planner's hash join over a sequential scan of `mc.visible`, 8 ms the same way by tid, 1.1-2.1 ms in the profiles.  Nothing between the probe and the delete changes a row of `mc.visible`.
* The stale players come out of the same scan, no statement runs when there is nothing to add or delete.

Not changed: the pairing bundles (`mc.pairing_bundle`, sql/903), the packets, `mc.vis_find`, the locator bar.  `tests/sql/981` now compares the scan version with `mc.refresh_visibility_vis_nb` (it injects pairs
that the rule does not hold for, state the boundary version is not built for).

## Where the rest goes

Walking bench, crowd, statements per tick (`PROF=1 tests/bench/game/walk.sh 1.1 70 crowd 500 30`; ms, loaded machine; 130 dirty players, 6,600 pairs near the edge, 168 new pairs):

| | 1.1 blocks / tick | 0.215 blocks / tick |
|---|---|---|
| visibility phase | 41.5 | 13.2 |
| candidate search (scan of the players 1, pair loop 8-9, probes and the arrays 7-9) | 22.0 | 6.1 (1.0 + 1.5 + 3.5) |
| new pairs: insert, **168 / 32 pairing bundles at 0.08-0.1 ms**, play_out rows | 13.7 | 3.7 |
| deletes (60 / 20 pairs) + play_out | 2.1 | 0.6 |
| `mc.vis_find` + the update of the evaluated players | 0.5 + 1.1 | 0.5 + 0.4 |

At 0.215 the floor (the scan of 500 players 1.0, `vis_find` 0.5, the update 0.4, plpgsql and the locator bar pass 0.3) and the bundles of the 32 new pairs are about 6 of 13 ms; the 5 times asked for would need
the whole tick of this function under 7 ms.

## Task 2: 500 sparse walkers (100 x 100 chunks, view distance 10, everybody moving)

`tools/scoreboard/cenv_capacity`, `capprof_live.sh 40` as in [PERF-CAPACITY.md](PERF-CAPACITY.md) "Reproduce", private cluster in `/dev/shm` with `pg_stat_statements` and `track_functions`;
`run.py pop --n 500 --moving 1.0 --spread 800 --bound 780 --hold 60` (the sparse cell of the campaign).  Profile of the boundary version ([perf-vis2-live-sparseB.txt](perf-vis2-live-sparseB.txt),
repeat in `...sparseB2.txt`; the neighbourhood version in `...sparseA.txt`), 40 s, 502 ticks, load 1.9:

| phase | ms per tick |
|---|---|
| tick average (wall) | **62.1** (run.py: mean 61.2, p99 101, tick CPU 65.1, gateway CPU 6.8; repeat 57.9 / 58.2 / 63.3) |
| process (inbox: 742 frames a tick) | 8.5 |
| game (`mc.tick_core`) | 30.6 |
| ... moves (`mc.apply_player_moves`: 502 whole-row updates of `mc.player` 4.7) | 9.5 |
| ... **visibility** | **10.0** (search 5.1, new pairs 1.9) |
| ... keepalive + dynamics + tracker (`vis_move` 5.5) + survival | 7.7 |
| ... survival | 2.1 |
| **chunk streaming** (`net.stream_chunks` 19.4: wanted rows 2.5, `deliver_ready_chunks` 12.7) | **19.3** |
| drain (`net.drain_outbox` 5.4: 526 rows) | 3.6 |
| WAL | 423 KB and 1,414 records a tick |

Top statements: `net.stream_chunks` 19.4, `deliver_ready_chunks` 12.7 (the loose scan for the connections 2.1, `chunk_wanted_view` clean-up 2.3, the round-robin pick 2.7, the delete by tid 1.2, the chunk packets 2.1),
`refresh_visibility_vis` 10.0, `apply_player_moves` 9.3, `net.process_fast` 7.6, `vis_move` 5.5, `drain_outbox` 5.4, `insert into mc.chunk_wanted` 2.5 (314 rows at 8 us: two indexes and an `ON CONFLICT`).

**The visibility change helps the sparse cell little**: 17.0 -> 10.0 ms in the live harness (the A run was on a busier machine: its `stream_chunks` took 28 ms against 19, so about 1.5 times slower; scaled,
11.6 -> 10.0), and the walking bench with 500 players over 100 x 100 chunks shows 9.8 -> 11.7 at 0.215 and 47 -> 27.5 at 1.1.  In a sparse world the old function already found its candidates in a few index
probes, and the new one still does a pass over all online players for each dirty one (13,500 pair tests a tick, 1.5 ms) and a scan of the players (1 ms); there is almost nothing to save.  The gain of the day
in this cell is not from this work: the tick average is 58-62 ms CPU 63-65 against the 131-143 / 141-155 ms of [PERF-CAPACITY.md](PERF-CAPACITY.md) (the target was 100 ms of CPU: **met on this tree**); the
change of that table's row is the dynamics track's (`dyn_step` is 0.6 ms a tick here against 17-28 then) and the scripted clients, so it is not attributed to anything of this work.

What was done in the top cost, the chunk streaming (31 % of the tick): `deliver_ready_chunks` finds the connections that have wanted rows with a loose index scan, a probe per connection (4 us each, 2.1 ms a tick
with 500 walkers); for a short queue (fewer than 3,000 rows) it is a plain `SELECT DISTINCT` now: 0.4 ms (measured on its own with 481 connections: 2.1 -> 0.4), the same connections in the same order
(`sql/791`; `tests/sql/437`, `920` and `984` cover the function).  The live run after it (`...sparseC.txt`) was on an overloaded machine (load 3-6, the tick 110 ms, the queue 54,000 rows: the loose scan was
still the path taken) and shows nothing; the gain, 1.7 ms of 62, is within the noise of any run here.

**Not done, and what it would take.**  The two costs that would matter (the numbers are from the profile above):
1. Chunk wanted rows are inserted (2.5 ms), read back (round robin 2.7), cleaned (2.3) and deleted (1.2) for chunks that exist and are sent in the same tick (241 of 314 a tick): delivering
   those directly would save about 8 ms of 62.  The packets per connection must stay the same: a connection with older wanted rows has them sent first (nearest first), and the shared cap of the tick
   (`dbcraft.chunk-budget-per-tick`, scaled by the time already spent) cuts round robin across connections, so the direct path is only the same output when no connection has a backlog and the cap
   is not reached; it needs its own differential test like `tests/sql/437` and 984.
2. `mc.apply_player_moves` rewrites the 111-column `mc.player` row of every mover (4.7 ms for 502 rows): a narrow position table (listed as not done in PERF-CAPACITY.md).

## What did not work, or was not worth it

* **A spatial grid for the candidates** (cells of a chunk or two, or the ring of cells around the circle).  Measured and computed: the loop over all online players costs 0.1 us a pair; the same candidates from the
  partial index on `(chunk_x, chunk_z)` cost one probe per cell column (1 us each, 20 columns for a circle of 160 blocks) or ring cells of 16 blocks (190 a dirty player, 0.15 us each), the ring of cells that
  can contain a pair whose bound is 10-20 blocks is 25-40 % of a crowd of 500 and the rest of the players are the same ones the loop skips cheaply; at 500 players, crowded or sparse, the grid is not cheaper than the loop.
  It would be at several thousand online players: **the candidate search here is O(dirty x online) with 0.1 us**, not O(changes); the probes, the inserts and the deletes are O(pairs near the edge).  At 1,000
  crowded walkers at 0.215 blocks a tick the phase measured 42.7 ms (the neighbourhood version 197), at 500 22.6 (63.6), at 250 6.7 (17.9).  An index-driven candidate source (the neighbourhood version's) for more than about 2,000 online
  players is the next step; the bound and the probes carry over unchanged.
* **A hash index on the pair key** for the probes (`((viewer_eid::bigint << 24) | target_eid)`): 6.6 against 8.3 ms for 7,400 probes, a fifth, not worth a second index.
* **Probing one direction of a pair** and skipping the other when it needs no change (both directions of a pair of equal players are evaluated together, so their state is equal): halves the probes, and
  made no difference in the bench (41.7 against 42.4 ms at 1.1) because the probes are cheaper than the cost of the rest of the statement; reverted, one invariant less to rely on.
* `plan_cache_mode = force_generic_plan` on the function (planning is 0.2-0.5 ms a statement): no change.
* A set-based `mc.pairing_bundle` (the bundles are the largest part of what is left: 70-120 us each, six small queries in a plpgsql function over a copy of a 641-byte row): not done, it would duplicate sql/903
  and drift from it.
* The first version of the test did not detect the mutations "no slack" and "stale player trusted": the random walks never drifted 4 blocks and came back, and teleports went across the world, which makes the bound
  huge anyway.  Jittering walkers and short teleports were added for them.
* Standalone EXPLAIN experiments mislead in two ways that cost time here: `512.0` as a literal makes the radius `numeric` (the pair loop became 2 times slower in the copy of the statement), and
  `select count(*) from (select (select ...) ...)` drops the probe it was meant to time.

## Reproduce

```
export DBCRAFT_PGDATA=/dev/shm/x/pg DBCRAFT_PGPORT=56330 DBCRAFT_TESTDB=mydb       # a private cluster (tools/pg-dev.sh start), a migrated database with the reference data (tests/sql/prun.sh builds one)
tests/bench/game/walk.sh 0.215 70 crowd 500 30            # the walking bench; PROF=1 for the statements per tick; 1.1 for the slow tick; ... 500 100 for the sparse world
tests/bench/game/vis_ab.sh 2 out.txt 500 30 0.215 1.1     # A (neighbourhood version, through tests/bench/game/vis_ab_old.sql) against B (sql/909), alternating
tests/bench/game/vis_micro.sh mc.refresh_visibility_vis 0.27 4.6 10     # the function alone on the state a walk left: CPU and wall, 27 % of the players dirty
psql -v fn=mc.refresh_visibility_vis_nb -v frac=0.27 -v step=4.6 -f tests/bench/game/vis_plan.sql     # the plans of its statements (auto_explain)
psql -f tests/sql/_harness.sql -f tests/sql/990_vis_boundary.sql      # the proof (3.5 minutes)
tools/scoreboard/cenv_capacity ...                        # the live cells, as in PERF-CAPACITY.md; the A side is tests/bench/game/vis_ab_old.sql applied to the cluster's database
```
