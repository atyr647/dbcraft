# The locator bar: what vanilla does, what it cost here, what was changed (LOCATOR)

The question: "look into locator bar losses and explain in more detail".  The locator bar is the row of player markers at the top of the screen (vanilla's **waypoint** packets).
The "loss" was two things: the bar was **half of a walking tick** at 50-120 players, and at the 121st player it was **switched off** (`dbcraft.locator-bar-max-players`), which made the
tick cheaper by more than the bar had cost and made dbcraft's 200-walker rows look better than they are (vanilla sends the bar to everybody).

**Short answer.**  Vanilla's work is O(movers x players) per tick (every position change of one player looks at all of its connections, as a transmitter and as a receiver), and it
sends a packet only when a connection's state changes.  The old dbcraft pass looked at **every pair of players on every tick in which anybody moved** (N x N rows) and built every packet
from scratch (8 us each).  The pass is now **dirty-driven**: it looks at the connections whose inputs changed, builds each source's packet once for all its receivers, and the cap is
gone (default 100,000, kept as an escape hatch).  **Measured (interleaved, same run): the pass costs 45-70 % of what it did at 50-200 players (44 % at 400, 83 % when the connections are mostly azimuth ones at 100 players); the cliff is gone.
The target "at most +3 ms over bar off at 50 / 100 / 200 players" is NOT met**: the pass is still about half to two thirds of the old cost, not a tenth of it (see "What is still a loss").
Raw numbers: `docs/perf-locator-results.txt`.  Not measured: vanilla's own CPU for the bar (section 5).

## 1. What vanilla does (26.3, `javap -c -p` of the server jar)

Classes: `net.minecraft.server.waypoints.ServerWaypointManager`, `world.waypoints.WaypointTransmitter` (+ `EntityBlockConnection`, `EntityChunkConnection`, `EntityAzimuthConnection`),
`LivingEntity` (`isTransmittingWaypoint`, `makeWaypointConnectionWith`, `onAttributeUpdated`), `ServerPlayer`, `Entity.setPosRaw`, `ClientboundTrackedWaypointPacket`.

* **Who sends to whom.**  Every `LivingEntity` is a `WaypointTransmitter`; it transmits while its attribute `waypoint_transmit_range` is > 0.  A player has 6.0E7 (60 million blocks) for
  both `waypoint_transmit_range` and `waypoint_receive_range`.  A crouching player gets the modifier `waypoint_transmit_range_crouch` (-1.0, ADD_MULTIPLIED_TOTAL): range 0, it stops
  transmitting; heads that hide you (carved pumpkin, mob heads) do the same through item attribute modifiers.  A change of the attribute calls `trackWaypoint` / `untrackWaypoint`.
  The game rule `locator_bar` (default true) is read per receiver, in `isLocatorBarEnabledFor`, every time a connection is made or looked at.
* **The connection table.**  `ServerWaypointManager` keeps a Guava `Table<ServerPlayer receiver, WaypointTransmitter, Connection>`: one **connection** per (receiver, transmitter) pair.
* **Which kind of connection** (`LivingEntity.makeWaypointConnectionWith(receiver)`): none if the source is in its first tick or is the receiver, or `doesSourceIgnoreReceiver` (receiver
  not a spectator and source a spectator, or the receiver rides the source, or distance >= min(transmit range, receive range)); else
  * distance > **332.0f** blocks (`isReallyFar`, `distanceTo`): **azimuth**, `lastAngle` = `Mth.atan2` of the receiver-minus-source offset turned a quarter clockwise;
  * else the source's chunk is **not inside the receiver's chunk tracking view** (`isChunkVisible`: the receiver's view distance): **chunk** (`lastPosition` = the source's `ChunkPos`);
  * else **block** (`lastPosition` = the source's `BlockPos`).
* **What a connection sends.**  `connect()` = TRACK (op 0), `disconnect()` = UNTRACK (op 1), `update()` = UPDATE (op 2).  `update()`: block kind: when the source's block position
  differs from `lastPosition` (Manhattan distance > 0) -> UPDATE with the new block; chunk kind: when the chunk differs (Chebyshev > 0) -> UPDATE with the chunk; azimuth: when the new angle
  differs from `lastAngle` by more than **0.008726646 rad (half a degree)** -> UPDATE.  `isBroken()`: block: Manhattan > 1 or ignored; chunk: Chebyshev > 1, ignored, or the chunk became
  visible; azimuth: ignored, or the chunk is visible, or no longer really far.  A broken connection is **remade** (`updateConnection`: a new connection of the kind that now applies, TRACK sent,
  **no UNTRACK before it**), or ended with an UNTRACK when none applies.  Icon: `locatorBarIcon` (style default, no colour): the packet carries it, the icon never changes in practice.
* **When it is evaluated.**  Not on a timer: from `Entity.setPosRaw`, i.e. **on every change of a position** (not in the first tick, only on a server level): if the entity transmits,
  `updateWaypoint(this)` (all connections of this transmitter: `updateConnection` for every receiver that has one, `createConnection` for every player that does not); if it is a
  receiving `ServerPlayer`, `updatePlayer(this)` (all connections of this receiver, and `createConnection` for every transmitter it has none to).  Both build a Guava `Sets.difference` and an
  `ImmutableSet.copyOf` of the entries: allocation proportional to the number of players on every call.  `addPlayer` / `removePlayer` (receive range attribute) and `trackWaypoint` /
  `untrackWaypoint` (transmit attribute, entity added / removed / dimension change) make or end the connections of the joining / leaving side.
* **How vanilla's cost scales.**  A player that **stands still costs nothing**.  Each position change of one player costs about 2 x (players - 1) connection checks (as transmitter and as
  receiver): `isBroken` is a few comparisons, an azimuth check adds an `atan2` and a distance, a "create" check adds `distanceTo` and the chunk view test.  With K players moving that is about
  2 K N checks per tick, **N x N when everybody walks**.  Packets: only on a state change; the number is the same as dbcraft's (below), they are the same packets.
  (The checks are cheap in the JVM, tens of nanoseconds; no measurement was made, section 5.)

## 2. What dbcraft did (before this work) and what it cost

`sql/908`: the same model in rows.  `mc.wp (rcv, src, kind, ang)` is the connection table (one row per pair, kind 1 block / 2 chunk / 3 azimuth, the angle of the last packet);
`mc.player.wp_bx.. wp_cz` remember the source's block and chunk as of the last pass (vanilla's `lastPosition`, shared by all connections of a source), `wp_state` the transmit state
(bit 0 transmits, bit 1 spectator), `wp_hidden` the hiding head.  `mc.vis_wp_pass(cur, phase)` ran in two places of every tick:

* phase 1 (movement, `mc.refresh_visibility`) whenever **any** player moved or changed block: a full join `players x players` (every ordered pair, N x N rows) with `mc.wp`, 20 expressions per pair
  (distance, view test, angle, block/chunk deltas), then the packets of the pairs that had an event: `mc.pkt_waypoint` per pair (a `wp_body` of five VarInt calls plus `proto.frame` of a
  packet id >= 128: about 8 us, docs/PERF-STORM.md), grouped per receiver in source order;
* phase 2 (entity phase) only for the pairs of a player whose transmit state changed.

**Why it was O(N^2):** the pair join does not know which pairs can have an event, so it computes all of them and throws almost all away.  The pair count is N (N - 1): 2,450 at 50 players, 9,900 at
100, 14,280 at 120, 39,800 at 200.  Per tick, with everybody walking (tests/bench/game/walk.sh, 0.215 blocks per tick, 30 x 30 chunks, view distance 10), only a few percent of the pairs had an event:

| players | pairs (rows) | block / chunk / azimuth rows | packets per tick | of which TRACK / UPDATE / UNTRACK | bytes per tick |
|---|---|---|---|---|---|
| 50 | 2,450 | 818 / 938 / 694 | 254 | 16 / 239 / 0 | 11,550 |
| 100 | 9,900 | 3,247 / 3,837 / 2,816 | 990 | 56 / 934 / 0 | 44,877 |
| 120 | 14,280 | 4,712 / 5,590 / 3,978 | | | |
| 200 | 39,800 | 12,850 / 15,352 / 11,598 | 3,900 | 188 / 3,712 / 0 | 176,701 |

Cost of the pass, in-database bench, CPU ms per tick of the backend (`tests/bench/game/walk_prof.sh`: `/proc/self/schedstat` around `mc.tick()`, warm-up 20 ticks, 40 measured; first block of
`docs/perf-locator-results.txt`, a quieter moment of the shared machine, one run each; the bar was forced on with the cap raised for 121 and 200):

| players | bar on | bar off | the bar costs | per packet of that tick |
|---|---|---|---|---|
| 50 | 10.05 | 5.17 | 4.9 | 19 us |
| 100 | 24.56 | 11.54 | 13.0 | 13 us |
| 120 | 30.90 | 13.75 | 17.2 | |
| 121 (cap raised) | 31.93 | 15.22 | 16.7 | |
| 200 (cap raised) | 75.71 | 28.68 | 47.0 | 12 us |

(The scoreboard's live 50-walker profile said 23 of 47 ms on a slower and busier machine; the in-database figures are about half of the tick as well: 49 %, 53 %, 56 %, 62 % of the tick.)
Per function (`pg_stat_user_functions`, `track_functions = all`, which inflates everything: 24 / 37 / 43 ms ticks): `mc.vis_wp_pass` 8.4 / 18.4 / 23.2 ms per tick, one call a tick, almost all of
it its own statement (self 7.7 / 16.9 / 21.3).  **The cost per state change** (an UPDATE / TRACK / UNTRACK packet): 12-19 us of the old pass, of which about 8 us is building the packet and the rest
the share of the pair scan (0.4-1 us per pair); at 200 walkers the 3,900 packets are about 31 ms of the 47 and the 39,800 pairs the rest.

**The cap.**  Above `dbcraft.locator-bar-max-players` (120) the pass ended every connection and did nothing after that (`vis_wp_pass`'s "off" branch).  That is the cliff: 26 ms at 121 walkers
against 62 at 120 in the live profile, 15 against 31 in the bench above.

## 3. What the cliff did to clients (d)

* **With the bar off** (cap exceeded or game rule false) a player sees **no other player on the locator bar**: no TRACK is sent, so the client's tracked-waypoint list stays empty.  Everything
  else the bar shows in vanilla comes from other waypoint sources (`/waypoint`, which dbcraft does not implement), so the bar was simply empty at 121+ players.  Vanilla's behaviour with
  the same game rule value false is the same (`createConnection` / `updateConnection` return at once).
* **Crossing the threshold upwards** (the 121st player joins, or the rule is switched off): the pass ended **every** connection in that tick: 120 x 119 = **14,280 UNTRACK packets** in one tick (1.2-1.6 s
  before the slicing of docs/PERF-STORM.md), each existing player received an UNTRACK for each other player (the joiner none: `mc.vis_wp_join` returns early).  Since then the UNTRACKs
  go out `dbcraft.locator-bar-untrack-slice` (1,500) connections per tick, in the same bytes and order (tests/sql/920).  So the markers of a crowd disappear over ten ticks.
* **Crossing it downwards** (a player leaves, 120 left): the pass is switched on again and finds `mc.wp` empty.  Connections are made **lazily**: a missing connection is made when the *receiver* moves
  (`may_create`), so every player gets its markers the first time it moves after that; a player that stays still has none (and the joiner of that moment gets its connections at once).
  That is vanilla's lazy rule as the old code approximated it (vanilla also makes them from the source's movement), and it is unchanged.
* **Now:** the default of the cap is 100,000; nothing happens at 121.  Set it to a number to get the old behaviour (an escape hatch for a server that cannot afford the bar).

## 4. What was changed: the dirty-driven pass (`sql/908`)

Principle: after every pass each connection **agrees with the positions of that pass** (what the pass did to it is exactly what a second pass over the same positions would leave alone), so a pair
has an event only when one of its inputs changed.  The pass finds those pairs by index instead of by joining everybody:

| connection | has an event when | found by |
|---|---|---|
| block (kind 1) | its source's block changed | `mc.wp (src) include (rcv) where kind = 1`, one probe per source whose block changed |
| chunk (kind 2) | its source's chunk changed; or the receiver's chunk or view distance changed (the chunk became visible) | partial indexes `where kind = 2` by source and by receiver |
| azimuth (kind 3) | either end moved: the angle changes, or the pair comes inside the view / under 332 blocks | partial indexes `where kind = 3`; when most players moved (or with a view of 14+ chunks, where a far connection can be inside the view and is remade on every pass) one scan of the kind (CTE `azc`) |
| missing | the receiver moved and it lacks a connection to a source it wants | `mc.wp_cnt` (connections per receiver, kept by statement triggers on `mc.wp`) against what the receiver wants |
| everything of a player the pass never saw | its transmit state is null (a joiner) | rows by receiver and by source |
| entity phase | the transmit state of a player changed | its pairs (as before, now by index) |

Where a pair was found, **the same evaluation as before decides** (the code of the old `pr`/`dc`/`ev` is kept), so a superset of candidates is harmless: a candidate that has no event costs time,
never a packet.  Three more changes carry the speed-up:

* **Packets are built once per source.**  The bytes of a block UPDATE do not depend on the receiver: the source's packet is built once (`sp`, `lp`), an azimuth packet is that prefix and the angle
  (`float4send`).  A walking source with 70 receivers: 1 build and 70 copies instead of 70 builds.  A source that moved exactly one block and is wanted by everybody (the bulk: 3,400 of the 3,900
  packets at 200 walkers) skips the evaluation altogether (`lset`, CTE `ln`).
* **Writes by tid** (`w.ctid = ev.tid`, the candidate scans carry the row address): with the connections' own statistics (never analysed, unlogged) the planner hashed the whole of `mc.wp` for a
  hundred updates (2 ms each); with `join_collapse_limit = 1` and `plan_cache_mode = force_generic_plan` on the function the plan is made once and cannot cross the player set with itself.
* **`mc.wp_far`**: the 332-block test decided from the sum of squares except within 0.05 % of the limit (the power operator was 300 ns a call: 5 ms a tick at 100 players).

The old pass is kept as **`mc.vis_wp_pass_pairs`** (sql/908), the differential reference; nothing in the server calls it.  Other changes: `mc.player.wp_vr` (the receiver's view radius as of the
last pass), the partial indexes, `mc.wp_cnt` (+ three triggers, which also fire under `session_replication_role = replica`, which `tests/sql/900` uses), the cap default 100,000
(`update` of an installed default of 120 in sql/908), and one fix of a rule: a *silent* move (a teleport, which does not set `last_move_tick`) is seen through `vis_dirty`, which `/tp` sets.

**Verification** (`tests/sql/1000_wp_dirty.sql`): the two passes run on the same state after every phase of every tick of random scenarios (tiny steps, walking, jumps of 20-3,000 blocks, 6 %
teleports, joins, leaves, crouching, game mode changes, hidden heads, view distances up to 20 chunks; worlds of 64 to 2,500 blocks; 17 scenarios, 840 ticks, 1,680 pass comparisons) and must leave the same packets
(every receiver's bytes in order), the same connections (kind and angle) and the same remembered state.  The scenarios send TRACK, UPDATE and UNTRACK of every kind.  **Mutation check:** 16
mutants (one way into the candidate set removed, or a rule changed: the angle threshold, remake instead of update, the lean path taking a spectator source ...) are each noticed by the same
scenarios.  Two real differences were found by the test and fixed before it passed: a teleport without `last_move_tick` (now `vis_dirty`), and the generator of the test itself drawing the
"silent" flag twice.  `tests/sql/900`, `920`, `971`, `981`, `982`, `984` pass with the new pass; the full suite is at the end of this file.

## 5. Measurements of the new pass (c) and what is still a loss

Interleaved in one run (`loc_ab`: `mc.vis_wp_pass` calls the reference on even ticks and the dirty-driven pass on odd ticks of the same walking bench, so both see the same machine noise; wall
ms of the movement pass of 40 ticks, median; the machine was shared, load average 3-4 on 4 cores, so every absolute figure below is 2-4 times what a quiet machine gives and **only the
ratios mean something**; `docs/perf-locator-results.txt`, "FINAL TREE"):

| players | reference pass (all pairs) | dirty-driven | ratio |
|---|---|---|---|
| 50 | 7.4 | 3.5 | 0.47 |
| 100 | 12.6 | 8.8 | 0.70 |
| 120 | 18.5 | 10.0 | 0.54 |
| 121 | 19.5 | 12.2 | 0.63 |
| 200 | 52.5 | 35.6 | 0.68 |
| 400 | 271 | 120 | 0.44 |
| 100, 60 x 60 chunks (mostly azimuth connections) | 12.6 | 10.5 | 0.83 |
| 200, 60 x 60 chunks | 43.3 | 30.1 | 0.70 |

(An earlier interleaved run, before the writes by tid and the join order: 50: 7.1 / 3.1, 100: 14.7 / 7.9, 200: 45 / 28.5, 400: 234 / 110; run-to-run spread of these ratios is about 0.15.)
Bar on against bar off with the dirty-driven pass, tick CPU ms (same machine, alternating, 2 repetitions): 50: 45.2 / 46.2 on against 42.0 / 40.7 off; 100: 54.9 / 57.4 against 43.1 / 48.3; 120: 64.8 / 68.9
against 54.5 / 50.1; **121: 72.1 / 75.7 against 52.5 / 57.2 (no cliff: the bar is on, nothing changes at 121)**; 200: 102.2 / 102.7 against 65.8 / 70.0.  The off tick itself was 4-8 times its quiet value (5.2
at 50 players), so these deltas (3-5, 9-12, 10-19, 18-20, 33-36 ms) are inflated by the same factor; the same machine moment gave the reference pass 7.4 / 12.6 / 18.5 / 52.5 ms wall.

**Target: NOT met.**  "At most +3 ms over bar off at 50 / 100 / 200 players": on this machine the pass is about 3.5 / 9 / 36 ms wall (shared, inflated 2-4 times; on a quiet machine perhaps 1.5 / 4 / 15),
so 50 players may reach it, 100 and 200 do not.  The old cost was 4.9 / 13.0 / 47 ms of tick CPU on the quiet machine.

**What is still a loss, and why it is not a bug of the design but a floor of this one:**

1. **Azimuth connections of players that move are examined every tick** (O(movers x far connections)): 0.7 us a row (scan, two hash joins with the player set, the distance and the angle), 11,600 rows at
   200 walkers (about 8 ms of the 17 ms statement on the loaded machine).  The connection of a far pair changes by 0.5 degrees only after some metres of relative movement, so most examinations find
   nothing, but a sound skip needs per-row state that is written when the row is *examined* (a deadline per connection), and a row write costs more than the examination it saves (3-5 us against 0.7).
   Tried on paper only: deadlines by tick with a speed bound (examined every 2-4 ticks instead of every tick), by odometer (the rows stay due until their event).
2. **The packets themselves**: 3,900 a tick at 200 walkers, 1.5 us each in the lean path (index entry, hash of the receiver, one copy), plus the per-receiver `string_agg` and the 200 `play_out` rows.
3. **Bookkeeping per mover**: the pass updates `wp_bx.. wp_cz` of every player whose block or chunk changed (a 15 us row update of the 111-column `mc.player` for 27 % of the walkers every tick).  A
   narrow position table would be 10 times cheaper; `mc.player` columns are read in hundreds of places (not done).
4. The statement is planned once (generic plan) but its plan is only as good as the estimates: a function-scan row estimate (`rows 1000`) and the join order are what keep it from hashing `mc.wp`.

**Vanilla comparison (e): not measured.**  The machine was shared with another agent's vanilla storm run (a JVM at 150 % of a core), a 3-minute cell per setting would have been noise, and the scoreboard
harness for `locator_bar` true against false was not set up inside the time budget.  What the bytecode says is in section 1: vanilla's cost is O(movers x players) checks and the same packets; the
scoreboard's 200 walking players (vanilla 45.8 ms, 1.84 cores, `docs/SCOREBOARD-SUMMARY.md`) include its locator bar in vanilla's number and were not compared with the bar on in dbcraft (the bar was off above 120).
The dbcraft figures above are therefore a lower bound of what the 200-walker row costs with the bar on; to compare, rerun the 200-walker row with this tree (the cap is gone).

## 6. Files and how to reproduce

* `sql/908_vis_waypoints.sql`: `mc.vis_wp_pass` (dirty-driven), `mc.vis_wp_pass_pairs` (reference), `mc.wp_cand`, `mc.wp_cand_missing`, `mc.wp_cand_state`, `mc.wp_far`, `mc.wp_vr`, `mc.wp_cnt` and its triggers.
* `tests/sql/1000_wp_dirty.sql` (differential + mutation), `tests/bench/game/walk_prof.sh` / `walk_prof.sql` (CPU per tick, packets, per function), `tests/bench/game/wp_micro.sh` (the pass alone, both
  versions alternately on one state).
* The interleaved run: a copy of the database whose `mc.vis_wp_pass` calls `mc.vis_wp_pass_pairs` on even ticks and `mc.vis_wp_pass_new` (the dirty-driven pass renamed) on odd ticks.

```
DBCRAFT_PGPORT=.. DBCRAFT_TESTDB=.. tests/bench/game/walk_prof.sh PLAYERS 60 LABEL [CAP 0=bar off] [SIDE] 0.215 [FUNCS=1] [COUNT=1]
DBCRAFT_PGPORT=.. DBCRAFT_TESTDB=.. tests/bench/game/wp_micro.sh PLAYERS 40 [SIDE]
tests/sql/prun.sh 1000_wp_dirty
```

## 7. Full suite (final tree)

`tests/sql/prun.sh` (JOBS=3, shared machine, 14 minutes): **85 files, 3,198 checks, all pass** (`tests/sql/1000_wp_dirty.sql` 39 checks, 220 s of them); `tools/check_overrides.py` (60 overrides, all listed),
`tools/check_inlining.sh` and `tools/check_fresh_migration.sh` (run at the end of `prun.sh`) green.  `tests/e2e` was not run (no recordings were made; the packet bytes are the ones `tests/sql/900` and the
differential test pin).
