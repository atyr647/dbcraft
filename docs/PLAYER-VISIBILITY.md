# What other players see, and how a player joins (SQL)

Everything a player sees of another player is a function of rows: entity data (sneaking, sprinting, pose, skin layers, main hand, health), equipment, attributes, arm swings,
the tab list, the locator bar (waypoints), movement, and who is in range of whom.  `sql/900`-`sql/910`, tests in `tests/sql/900_vis.sql` and `tests/e2e/vis_probe.py` /
`compare_vis.py`.  Every rule below is either read from the 26.3 bytecode (`javap -c` on the classes of the pinned jar: `ServerEntity`, `ChunkMap$TrackedEntity`,
`ServerGamePacketListenerImpl`, `ServerWaypointManager`, `WaypointTransmitter`, `Player`, `ServerPlayer`, `TickThrottler`) or something two scripted clients saw the **real vanilla
server** send, and the last section lists what is neither.

The whole layer is switched by the server property `dbcraft.vanilla-tracker` (default `true`).  `false` gives the older, simplified broadcast (an `add_entity` packet alone, a
movement packet on every second tick from the first change on, the returning-player join burst for everybody, chunk-square visibility with the server's view distance); the older
tests of the other modules pin that behaviour and run with it.

## What was built

| Rule | Where | Source |
|---|---|---|
| **Entity data** of a player in one `set_entity_data` per tick with every changed entry, in index order: 0 flags (crouching `0x02`, sprinting `0x08`, invisible `0x20` for a spectator), 6 pose, 8 using an item, 9 health, 15 main arm, 16 skin layers, 18 score; to the player and to the viewers | `833` `survival_tracker` (extended), `901` | `SynchedEntityData`, recorded |
| The **shift key** (`player_input`) sets the crouch flag at once; the **pose** (crouching only while the shift key is down and the player is not flying) is recomputed in the entity phase, so it reaches the viewers one tick after the flag; a shift key pressed and released in one tick still sends the flags (the entity data is dirty although the value is back) | `904`, `905` | `handlePlayerInput`, `Player.updatePlayerPose`, recorded |
| `client_information`: skin layers (16), main arm (15), the **hat** bit of the tab list (`player_info_update` action `0x80`, to everybody, only when it changed), the requested view distance | `904`, `430` (`net.process_fast` hands the packet to the game too) | `ServerPlayer.updateOptions`, recorded |
| **Swing**: `punch` becomes a `swing_animation` (hand, type, duration of the item's `attack_animation`: whack 6 for nearly everything) to the viewers, not to the swinger; a second swing in the first half of the animation is ignored; placing a block sends two | `904`, `432` | `handlePunch`, `LivingEntity.swing`, recorded |
| **Equipment**: the six visible slots (main hand, off hand, feet, legs, chest, head) are compared per slot with what the viewers were last sent (item, count, components); only the changed slots go out (`set_equipment`, ascending slot order, to the viewers only); a trigger on `mc.inventory_slot` marks the owner so a tick without inventory activity costs one comparison of a flag | `900`, `902`, `905` | `LivingEntity.detectEquipmentUpdates`, recorded |
| **Attributes**: movement speed with the sprinting modifier, the interaction ranges with the creative-mode modifiers, the modifiers of worn and held items (armor, armor toughness, attack speed ...: `ref.item_attr`, loaded by `tools/load_item_components.py` from the generator's per-item reports); a changed attribute goes out as `update_attributes` to the player and the viewers: sprinting at once, an equipment change one tick later, a game mode change one tick later | `901`, `902`, `905` | `AttributeMap`, `Attribute.isClientSyncable`, recorded |
| **Pairing bundle**: a viewer who starts to see a player gets `bundle_delimiter`, `add_entity` (the exact position and angle bytes the tracker last sent), `set_entity_data` (the non-default entries), `update_attributes` (the instances in the player's attribute map; none for a first-time player), `set_equipment` (non-empty slots), `bundle_delimiter` | `903` | `ServerEntity.sendPairingData`, recorded |
| **Movement**: `ServerEntity.sendChanges` ported: the body runs on every second tick of the player's age (updateInterval 2), a step's `ticks` is 2 (the first body after creation is a linear packet), the position counts as changed from 0.00276 blocks away from the exact position last sent, a refresh is sent every 60 ticks, a **full position sync** (`entity_position_sync`) replaces the delta when the on-ground flag changed, after 400 bodies, or when the delta does not fit in a short (more than 8 blocks), `move_entity_rot` when only the packed yaw/pitch byte changed, `rotate_head` when the packed head yaw changed; the head follows the yaw one tick later | `907` | `ServerEntity.sendChanges/createMovePacket`, `VecDeltaCodec`, recorded |
| A server-side teleport (`/tp`) puts the player off the ground for a tick (so the tracker sends two syncs, as the real server did), nothing else is sent by the command itself | `350`, `905` | recorded |
| **Locator bar** (waypoints): one connection per pair of players, of kind block position / chunk / azimuth; `TRACK` (0) when it is made, `UPDATE` (2) when the block moved by one block or the chunk changed, a jump remakes it (a `TRACK`, no `UNTRACK`), `UNTRACK` (1) when the source stops transmitting (crouching, a hiding head, a spectator seen by a non-spectator, gamerule `locator_bar` false) or leaves; a missing connection is made when the receiver sends a movement packet | `908`, `330` | `ServerWaypointManager`, `WaypointTransmitter`, recorded (block, chunk; azimuth is read from the bytecode only) |
| **Who sees whom**: the viewer's circle `R = min(512 * entity-broadcast-range-percentage / 100, view distance * 16)` blocks around it, horizontal and exact; a spectator is seen only by spectators; the view distance is the one the client asked for (default 2), clamped to 2..server | `909`, `468` | `ChunkMap$TrackedEntity.updatePlayer`, `getPlayerViewDistance`, recorded (`range`, `view`) |
| **Chunks per client**: the square sent to a client has the radius `view distance + 1` of ITS view distance; a changed view distance sends the new ring or forgets the outer one (no `set_chunk_cache_radius`: the real server sends none); forgets are ordered x ascending, then z | `436`, `430` (`hook_chunks`), `791`, `432`, `836` | recorded (`view`) |
| **Latency**: every 601 ticks `player_info_update` (action `0x10`) with every player's latency to everybody | `905` | `PlayerList.tick` (the value is milliseconds measured in ticks, see below) |
| **First-time vs returning** join: a first-time player's entry burst carries an empty `recipe_book_add`; the first tick sends `set_entity_data`, the recipes, `update_advancements`, `set_health`, `set_experience`; its attributes follow two ticks later and it is not on the ground for its first body.  A returning player's burst carries the recipes, and `update_attributes` follows `set_entity_data` | `906`, `150` | recorded (`join`) |
| **Chat rate limit**: 20 per chat message and 20 per command on separate counters that lose 1 per tick; a non-operator whose counter reaches 20 * `chat-spam-threshold-seconds` (`command-spam-threshold-seconds`, default 10) is disconnected with `disconnect.spam` | `910` | `detectRateSpam`, `TickThrottler` |

## One tick

```
network phase    mc.apply_player_moves (positions, last_move_tick)  >  mc.apply_chat (commands: /tp, /gamemode)  >  survival_input
mc.refresh_visibility          mc.vis_wp_pass(1): waypoint UPDATE / remade TRACK for this tick's movement   >   pairing and removal (bundles)
mc.vis_step      vis_input: player_input, punch (swing out at once), client_information (hat out at once), player_abilities   >   vis_chat_spam
tracker pass     survival_tracker: ONE set_entity_data per player with every changed entry   >   vis_move: the movement body / position sync / rotate_head
                 vis_first_tick: what a new entity made dirty (second set_entity_data, attributes of a returning player)
entity phase     vis_wp_pass(2): TRACK / UNTRACK when a source starts or stops transmitting   >   vis_entity_phase: ground after a /tp, pose, equipment, attributes, latency   >   head
mc.survival_entities   (damage from the entity tick, food, health, experience)
```
`mc.vis_step` is the only line added to `mc.tick_core` (sql/837).  Every step finds its players with one comparison of columns (`sent_*` against the current values) so a
tick in which nobody changes anything costs a few scans of `mc.player`.

## Verified against the real server

`tests/e2e/vis.sh record` starts a vanilla 26.3 server (survival, flat, no mobs, view distance 3, a fresh world per scenario) and drives two scripted clients, "Act" and
"Obs", through the scenarios of `tests/e2e/vis_probe.py`; `tests/e2e/vis.sh compare PORT` runs the same steps against dbcraft over TCP and `tests/e2e/compare_vis.py` requires the
packets of every step of both clients to be **equal, in the same order**.  Masked: entity ids (named by order of appearance), the order of the entries of one `update_attributes` (a hash set in
vanilla), latencies, sounds, keep-alives, the clock, chunk data, recipes and advancements (their content).

Result of the last full run (`tests/e2e/vis.sh compare`, dev gateway, survival, view distance 3; a step is one scripted action followed by what each client received until it went quiet):

| Scenario | What it does | Act (the actor) | Obs (the observer) |
|---|---|---|---|
| `join` | Obs online; Act joins for the first time, is seen, leaves; joins again | 2 of 2 steps **identical**, and 2 of 2 in the second session | 7 of 7 steps **identical** (login burst, Act's first and returning join, the pairing bundle, the tab list, the locator bar, the leave) |
| `pose` | crouch, sprint, swing, skin layers, hat, armor, held item, game modes | 28 of 30 identical; the 2 others differ only in the order of the modifiers inside one attribute (armor) | 25 of 30 identical; 3 armor/survival steps differ in that modifier order (one of them also when the dev gateway ticked between the two client packets of "legs and feet", which then go out as two `set_equipment`), `spectator` differs in the order of one position sync, `update_attributes` and the removal, `adventure` in the order of the waypoint and the tab-list update |
| `walk` | walking, sprinting, turning, jumping, 7/9-block moves, `/tp` 10, 40 blocks and next to Obs | 13 of 14 identical (movement is compared as totals per step); the teleport next to Obs differs: dbcraft pairs Obs at once, vanilla at Act's next movement packet (the scripted client sends none after `/tp`) | 11 to 12 of 14: the jump differs (vanilla's `needsSync` bodies), the add-entity of a teleported player carries the velocity vanilla has and dbcraft does not, and a walking step can miss a movement body or two when the dev gateway (18 Hz in PL/Python) merges client packets |
| `latency` | an idle player for 38 s | 2 of 2 identical (the broadcast and the refresh are counted, not their values) | 2 of 2 identical |
| `range` | Act walks away and back along x, 256 blocks | 25 of 26 identical; the add-entity bundle and the chunk forgets of the way back are in the other order | 25 of 26 identical; the order of two waypoint packets differs once |
| `view` | the client asks for view distances 2 to 10 and changes them | 8 of 8 **identical** (ring sends and forgets, no `set_chunk_cache_radius`) | 8 of 8 **identical** |

The comparison is not deterministic to the last step: the dev gateway ticks at about 18 Hz under load and the vanilla recording is one run.  Repeating `join` four times gave
identical results in three and one extra `entity_position_sync` at the end of the window in the fourth.  The packets that are **pinned byte for byte** by `tests/sql/900_vis.sql`
(76 checks, run by `tests/sql/prun.sh`) come from the recordings; the cases above are what differs between the recording and a run.

## Not verified, not built

* **Modifier order inside one attribute**: vanilla lists a player's modifiers in the order they were added (helmet, chestplate, then boots, leggings: slots in ascending ordinal
  within one tick); dbcraft lists them by slot (feet, legs, chest, head, main hand last).  The two armor steps of the `pose` scenario differ for that reason and only that.
  The order of the ENTRIES of one `update_attributes` is a hash set in vanilla (a different order every run) and is masked by the comparison.
* **Azimuth waypoints** (a source more than 332 blocks away): the rule is read from the bytecode and the packet layout from the other two kinds; the recorded runs reached 256 blocks.
  The angle uses `atan2` in double arithmetic cast to float; vanilla's `Mth.atan2` may differ in the last bit.  Waypoint rules for hiding heads (carved pumpkin, mob heads) and
  for a viewer who becomes a spectator are read from the bytecode, not recorded.
* **Movement bodies that vanilla triggers by `needsSync`** (the start of a jump, knockback, being pushed by another entity, `set_entity_motion`): a jump start shows up in
  vanilla as a sync with `ticks` 1 followed by a linear zero move; dbcraft sends the sync with `ticks` 2.  Entity motion packets, vehicles, passengers, gliding and swimming are not
  modelled.  The `walk` comparison therefore compares movement as totals per step (which tick of a step a body falls on depends on the entity's age), everything else packet for
  packet; the bytes of single movement packets are pinned by `tests/sql/900_vis.sql` against recorded packets.
* **Spectators**: a spectator is never on the ground from the entity phase after the game mode change (recorded: one `entity_position_sync` with the flag cleared); what happens to
  the flag when the player returns to survival (vanilla's recording showed no extra sync) was not reproduced.
* **Who sees whom is re-evaluated** when a player joins, is teleported, changes chunk, moves 4 blocks from where it was last evaluated, changes game mode (at the next movement
  packet of anybody), or its client changes the view distance; vanilla re-evaluates a pair on every movement packet of either player.  A player may therefore appear or disappear
  up to 8 blocks away from the exact circle, and vanilla's one-sided transient states (A sees B while B does not see A) are not reproduced.  Chunks still pending delivery are not
  considered (the circle always lies inside the chunk square).  After a `/tp` vanilla pairs the teleported player as a TARGET at once but as a VIEWER only at its next movement
  packet (a real client sends one immediately, the scripted client does not): dbcraft pairs both ways at once (`walk`, "teleport next to Obs").  Whether the add-entity bundle or the chunk
  forgets of a teleported player come first was recorded in two cases that disagree with each other (`walk` after `/tp` to Obs's side: no bundle in the window at all; `range`, `/tp`
  followed by position packets: bundle first, then the forgets); dbcraft pairs a teleported viewer after its chunks were sent, which matches neither exactly (the one `range` step).
* **Latency**: the value is the keep-alive round trip counted in ticks and smoothed like vanilla; the real server measures milliseconds.  The broadcast is every 601 ticks of game time,
  vanilla's counter starts with the server process.  The comparison counts the broadcasts, it does not compare their values.
* **First-time joins**: the recipe list, the advancement update and the command tree are still the captured bytes (`net.static_packet`; not generated from rows).  Vanilla spreads
  a first-time player around the world spawn; dbcraft puts everybody on it.  The first body of a first-time player is "not on the ground" as recorded; its pose, health and
  inventory start from the row defaults.
* **Equipment**: stacks with data components are forwarded with the bytes the inventory stores (not decoded), attribute modifiers come from the item's default components only (an
  enchanted or renamed stack is treated as its base item), the body and saddle slots are not modelled.
* **Chat and command rate limits** follow the bytecode (counters, thresholds, `disconnect.spam`, operators exempt) and are tested in SQL only: no vanilla recording of a spam kick.
  Signed chat is out of scope.  `/title`, `/tellraw` and the other text commands belong to the commands track and are not built here.
* **Entity data not modelled**: on fire, swimming, gliding, glowing, custom names, the air supply, absorption, the shoulder parrots, pose values other than standing and crouching.
* **Scale**: the locator bar is a row per pair of players per tick: above `dbcraft.locator-bar-max-players` (default 120) it is switched off (see the cost table), a large crowd also
  pays for one add-entity bundle per viewer.  The movement fan-out no longer uses the per-chunk "cell" blob of `sql/430_tick_perf_fanout.sql` with the tracker on: who sees whom
  is not a function of the chunk any more.  The batched tick (`mc.server_tick_batched`, `sql/389`) does not run any of this.
* **Entity tracker of mobs** (`sql/530`-`551`) still uses the server's view distance and a chunk-distance rule for mobs; only players are tracked by the new rule.
* A real vanilla client was not used (the scripted clients answer like one); online mode was not involved.

## Cost per tick

Measured with `tests/bench/game` (500 players over 100 x 100 chunks, every tick `bench.gen` > `mc.tick` > `bench.drain`, 120 ticks, the first 20 skipped) against the commit this work
started from (c914d77, built from a source archive into a separate database).  The machine was shared with other jobs (load average 10 to 15 on 4 cores), so **wall time is not
meaningful** (the same baseline ran 146 to 185 ms); the table is the CPU time of the one backend that runs the ticks (`/proc/self/stat`, two runs each; it contains the bench's own
move generation and drain, a constant of about 10 ms):

| Moving | baseline c914d77 | this tree, `dbcraft.vanilla-tracker = false` | this tree, tracker on (default) |
|---|---|---|---|
| 0 % (idle crowd) | 12.7 ms | 15.1 ms | 25 to 27 ms |
| 20 % | 36.6 ms | 37.2 ms | 49.9 ms |
| 100 % | 59.8 to 60.1 ms | 62.8 to 63.8 ms | 90 to 104 ms |

* With the tracker **off** the cost is +3 ms (+5 %), the price of the new columns and the extra checks in the movement path.
* With the tracker **on**, 500 players who all move cost about **+30 to +40 ms per tick** (the 50 ms budget is exceeded; the baseline was already at its edge), an idle crowd about +12 ms.
  Where it goes at 100 % moving (wall ms per tick on the loaded machine, sum 61): `vis_move` 25 (every second tick: the movement bodies, one wide `UPDATE` of `mc.player`), `vis_input` 13 (a scan of
  `mc.play_in_work`, a bloated queue in this benchmark that `tick_core` also scans), `vis_head` 9.5 (the head follows the yaw: another `UPDATE` of every rotating row), the entity phase 4.5, the
  entity-data pass 4, row initialisation 2, first ticks 2, waypoints 1.  The cost is the rewriting of wide `mc.player` rows several times a tick, not the arithmetic.
  A narrow table for the tracker columns (base position, sent angles, counters) would make most of it go away; it was not done.  `vis_move` skips players nothing can happen to (one comparison
  each), which helps an idle crowd less than hoped on this noisy machine.
* The tracker sees **fewer pairs** than the classic broadcast (14 against 19 viewers per player at view distance 10: a circle instead of a square), so it queues half the output rows (276 against 542 per tick).
* The **locator bar** is not in these numbers: above `dbcraft.locator-bar-max-players` (120) it is switched off, and its cost at that size was not measured.  It is a row per pair of players.
* With a few players the cost is invisible: the steps of `mc.vis_step` are each a scan of `mc.player`.

To repeat: build two databases (the old tree from a source archive, this tree), run `tests/bench/game/run.sh 500 100 1.0 120` for the wall-time report of the phases, and read the CPU time of the
session around the ticks (`pg_read_file('/proc/self/stat')`, fields 14 and 15); the two helper scripts were scratch files and are not in the repository.
