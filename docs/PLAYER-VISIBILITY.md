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

RESULTS_TABLE

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
  considered (the circle always lies inside the chunk square).
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

COST_TABLE
