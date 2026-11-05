# Survival core for players (SQL)

Health, hunger, fall and void damage, death, respawn, natural regeneration, eating and experience, as set-based SQL: `sql/830`-`sql/837`, tests in
`tests/sql/830_survival.sql` and `tests/e2e/survival_probe.py` / `compare_survival.py`.  Everything below is either a number read from the 26.3 bytecode
(`javap -c` on the classes of the pinned jar, as `tools/pkt_layout.py` does) or something a scripted client saw the **real vanilla server** do, and what is not
verified is listed at the end.

## What was built

| Rule | Where | Source of the numbers |
|---|---|---|
| Health, food, saturation, exhaustion, the food tick timer, `set_health` (when health, food or "saturation is 0" changed), `set_experience` | `830` columns of `mc.player`, `833` `survival_food` / `survival_sync` | `FoodData.tick`, `FoodConstants`, `ServerPlayer.doTick` (bytecode); the recorded run |
| Natural regeneration: saturated and hurt every 10 ticks (`min(sat, 6) / 6` health, that much exhaustion); food >= 18 every 80 ticks (1 health, 6 exhaustion); starvation every 80 ticks (1 damage: above 10 health, on hard always, on normal above 1 health) | `833` | `FoodData.tick`; gamerule `natural_health_regeneration` |
| Peaceful regeneration (+1 health and +1 saturation every 20 ticks of the player's tick count, +1 food every 10) | `833` | `ServerPlayer.tickRegeneration`; the phase is `game tick - join tick` (vanilla's own tickCount) |
| Exhaustion sources: sprinting (0.1 per metre, `0.1F * cm * 0.01F` in float), jumping (0.05, 0.2 sprinting), breaking a block in survival (0.005), damage (the damage type's `exhaustion`); none for creative/spectator | `833` `survival_pre` / `survival_moves`, a one-line hook in `432` | `ServerPlayer.checkMovementStatistics`, `jumpFromGround`, `Block.playerDestroy`, `Player.actuallyHurt` |
| Fall damage: `fallDistance -= (float) dy` while falling, on the ground `floor(fallDistance + 1e-6 - 3)` (x0.2 on hay and honey blocks, x0 on slime), reset on landing, moving up and teleport; creative and spectator take none; the landing particles | `833` `survival_moves` | `Entity.checkFallDamage`, `LivingEntity.checkFallDamage/causeFallDamage/calculateFallDamage`, `Player.causeFallDamage`, `ServerGamePacketListenerImpl.handlePlayerPositionChange`; the recorded fall |
| Void damage: 4 per hit below `min_y - 64` (-128 in the overworld), bypasses invulnerability (creative dies too) | `833` `survival_void` | `Entity.checkBelowWorld`, damage type tags |
| The damage pipeline `mc.hurt(entity ids[], amounts[], type, tick)`: invulnerable game modes, type tags, game rules (`fall_damage`, `drowning_damage`, `fire_damage`, `freeze_damage`), difficulty scaling (only for types with scaling `always`), the 10-tick damage cooldown (only the part above the last hit, no event), exhaustion, the combat window, `damage_event` to the player and everybody who sees them | `832` | `Player.hurtServer`, `LivingEntity.hurtServer`, `Player.actuallyHurt`, `DamageSource`; damage types and tags come from `ref.dp_*` (the same rows the client's registries are built from) |
| Death: `player_combat_kill` with the vanilla death message (`death.attack.<id>`, `death.fell.accident.generic` for falls above 5 blocks), the message to everybody (gamerule `show_death_messages`), `entity_event` 3, the inventory dropped as item entities (see below), `entity_event` 60 and the removal 19 ticks later | `832` `survival_die`, `836` `survival_deaths` | `ServerPlayer.die`, `CombatTracker.getDeathMessage`; the recorded `/kill` and void deaths |
| Respawn (`client_command` perform_respawn): the 21 packets `PlayerList.respawn` sends in the order the real server sent them, then the chunk batch; state reset, experience lost unless `keep_inventory` | `836` | the recorded respawn; `net.static_packet` for the command tree and attributes |
| `/kill [name]` (`mc.cmd_kill`, feedback `commands.kill.success.single`), `mc.kill_players(uuid[])`, `mc.damage(uuid, amount, type)`, `mc.heal` | `832`, `836` | recorded |
| Eating: `use_item` with a food item starts it (hungry, or always edible, or creative), the item's consume time (apple 32 ticks), `entity_event` 9, food and saturation (`FoodData.add`), the stack shrinks, a bowl or bottle stays; releasing cancels | `834`, `835` | `Foods`, `Consumables`, `Items` read by `tools/gen_survival_food.py` (44 foods); `LivingEntity.completeUsingItem`; the recorded apple |
| Experience: `mc.xp_give(points)`, `xp_give_levels`, `xp_set_levels`, `xp_set_points`, the level formula (7+2L, 37+5(L-15), 112+9(L-30)), `set_experience`, the player score entity data | `832`, `831` | `Player.giveExperiencePoints` (float arithmetic), recorded `/experience` runs |
| Game modes: creative and spectator are invulnerable (except to `bypasses_invulnerability`), take no fall damage, spend no exhaustion; survival and adventure are not | all | `Player.isInvulnerableTo/hurtServer`, `causeFoodExhaustion` |

`mc.tick_core` (`837`, listed in `sql/OVERRIDES.txt`) runs the steps in vanilla's order: `survival_pre` (sprint flags, a snapshot of the survival players' positions) >
moves > `survival_moves` (fall) > misc input > chat and commands > `survival_input` (respawn, start eating) > visibility > `survival_entities` (entity data
"tracker pass", deaths, void, finishing the meal, food tick, `set_health`/`set_experience`).  That order reproduces the recorded timestamps: damage that comes with the
player's own packets (a fall, `/kill`) reaches the viewers' entity data in the same tick, damage from the entity tick (void, starvation, regeneration) one tick later.
The **batched tick** (`mc.server_tick_batched`, `sql/389`) does not call `mc.tick_core` and therefore does not run the survival steps.

## Verified against the real server

`tests/e2e/survival_probe.py` drives two scripted clients (an operator "Surv" and an observer "Obs") against vanilla 26.3 (survival, normal, no mobs, spawn
radius 0) and against dbcraft over TCP; `tests/e2e/compare_survival.py` reduces both recordings to the packets the survival rules produce (entity ids masked, sounds,
entity motion, waypoints, the forced "player standing on air" block update and the command tree ignored) and requires them to be equal.

| Scenario (two scripted clients, in order of what each receives) | Packets compared, player / observer | Result |
|---|---|---|
| **fall**: `/tp` 12 blocks up, fall with client physics, land, regenerate until the saturation is gone | 25 / 12 | identical, in order, byte for byte (masked: the entity id) |
| **kill**: `/kill`, the death animation, respawn | 28 / 6 (vanilla sent 8 to the observer) | identical; the two extra are vanilla's second `set_entity_data` of the player that comes with the respawned entity (entity metadata of other players is not implemented, `docs/GAME.md`) |
| **void**: teleport to y = -140, six hits 10 ticks apart with regeneration between, death, the corpse removed | 34 / 21 | identical |
| **eat**: an apple at food 19 / saturation 0 (the state vanilla reached with the Hunger effect, copied into dbcraft with `UPDATE`) | 5 / 2 | identical (the eater gets `entity_event` 9, the observer does not) |

Sounds are compared by `tests/e2e/compare_sound.py` (see [Sounds](#sounds)).  Not compared by the harness although vanilla sent them: `set_entity_motion` after a hit, the one forced `block_update` below a landing player (vanilla
only), `update_advancements` after eating, `waypoint`, and the operator's command tree in the respawn burst (dbcraft replays a
recorded level-0 tree).  The second `set_entity_data` and `update_attributes` of a respawned player that vanilla's observers get after the add-entity bundle are sent here since `sql/836` (`mc.survival_resp_dup`) and compared.  Reproduce: `tests/e2e/survival.sh record VANILLA_PORT` (a vanilla server in survival, normal, no mobs, spawn radius 0, "Surv" an operator), then
`tests/e2e/survival.sh compare DBCRAFT_PORT` (see the header of that script for the dbcraft side).

In SQL (`tests/sql/830_survival.sql`, 136 checks) the same recordings are replayed through the tick functions and compared byte for byte: the **fall** (particles with
count 100 computed from the distance before the last step, `damage_event`, entity data, `set_health 11.0`, then ten `set_health` packets whose health and saturation
cascade matches the recording bit for bit, at the same tick offsets 9, 19, ..., 89 and 90), the **void** (hits every 10 ticks, 11 `set_health` packets incl. the death
one with saturation 1.0 because a dead player's food tick still runs, the death packets, the corpse removed 19 ticks later), **/kill** and the respawn burst, the
**apple** (flag, 32 ticks, `entity_event` 9, `set_health 20/20/2.4`, one tick later the flag and the slot), the **experience** sequence of six commands (found: the wire
order is progress, **level**, total; `net.play_entry_packets` wrote total first and was wrong for any player with experience).

## Not modelled, not verified (read this)

* **Armor, enchantments, potion effects, absorption, shields, totems**: damage is never reduced by them, no effect (hunger, regeneration, poison, fire resistance ...) exists.
  Food effects (golden apples, rotten flesh, ...) are not applied; only nutrition and saturation are.
* **Nothing but the void, falls, starvation and `/kill` hurts a player**: there is no fire, lava, drowning, cactus, explosion, mob or player attack in this server; the
  pipeline takes any damage type (`mc.hurt`) and difficulty scaling, `damage_event` and death messages for the types without an attacker exist, but the messages that name
  an attacker (`death.attack.mob`, assisted falls) need entities that do not exist.  Water is not recognised: a fall into water hurts, drowning does not exist.
* **Item drops on death** need the entity simulation: with `dbcraft.entity-mode = inline` every stack becomes an item entity (random sideways throw, 40 tick pickup
  delay); with the default `off` and with `split` (the entity connection owns `mc.entity`) the inventory is **cleared** and the items are gone.  Experience orbs are not
  spawned: the experience is lost on death.
* **Respawn** is always at the world spawn (vanilla spreads respawns over `spawn_radius`; the recorded run used radius 0); beds, respawn anchors, `immediate_respawn`
  behaviour of the server side, hardcore, and respawning in another dimension are not modelled.  A player who disconnects dead comes back alive (vanilla keeps the death screen).
* **Packets sent by vanilla and not by dbcraft**: `set_entity_motion` after a hit (vanilla sends the victim's `getDeltaMovement` to the victim and the viewers: (0, -0.0784, 0) for a standing player, the last movement for a falling one: `01 faff7ffe7569` after the recorded 12-block fall, `05 f9ff7ffeebed` after `/kill`), the one-time forced `block_update` below a landing player, `update_advancements` after eating, `hurt_animation`
  (only sent for knockback, which needs an attacker), `player_combat_enter/end` (vanilla sends them only for damage with an attacker entity: `CombatTracker.recordDamage` checks `isCombatRelevant`), the `waypoint` packets.  The respawned client gets the recorded command tree
  (`net.static_packet`), not the operator's tree vanilla sends.
* **Not checked against vanilla**: hay/honey/slime fall factors (read from the bytecode only), the starvation cases on easy and hard, peaceful regeneration (cadence from the
  bytecode, the phase against vanilla's `tickCount` is approximated by the join tick), the gamerule paths, `keep_inventory`, hunger from sprinting and jumping (the tick order
  of the exhaustion is the packet phase for movement and one tick later for block breaking), eating for any item but the apple, the `show_death_messages=false` empty message,
  cooldown behaviour against real mobs.  Online mode and a real vanilla client were not used: the clients are scripted.
* **The batched tick** does not run any of this; `mc.tick_core` (used by `mc.tick` and `mc.server_tick`) does.
* The `player_loaded` gate is not implemented: a player is vulnerable from the join tick.  Vanilla (read from `ServerGamePacketListenerImpl`: `hasClientLoaded`, `tickClientLoadTimeout`, `restartClientLoadTimerAfterRespawn`, `markClientUnloadedAfterDeath`) makes the player invulnerable (`ServerPlayer.isInvulnerableTo`: `!connection.hasClientLoaded()`, for every damage type) and ignores `player_input`, movement, `player_action`, `use_item_on`, `use_item`, `player_command`, `attack`, `interact` from the join, and from every respawn, until the client sends `player_loaded` or 60 ticks have passed.  Left out on purpose: every SQL test that injects damage right after a join would need the flag; the change is `mc.player.load_until` (join tick + 60, cleared by `net.hook_player_loaded`, set again by `mc.respawn_player`), a test in `mc.hurt` and a delete of the gated packet kinds in `mc.survival_pre`.
* Armor value and max health are fixed at 20 health (no attribute system).

## Sounds

Recorded from the real server and compared in order with `tests/e2e/compare_sound.py` (scenarios `fall`, `kill`, `eat`, `place`, `chest` of `tests/e2e/sound.sh`; the seed of every sound and the pitch of the random ones are masked): the others in range (16 blocks, strictly less) hear a player's **fall** (`entity.player.big_fall` for damage above 4, else `small_fall`, then the block fall sound at volume x 0.5 and pitch x 0.75, both before the damage event), a **hit** (`entity.player.hurt`, right after the damage event) and a **death** (`entity.player.death`), and the **eating** (`entity.generic.eat` every 4 ticks of the last 24, 7 for an apple); everybody hears the finished item (`entity.generic.eat` NEUTRAL, then `entity.player.burp`).  The player's own client plays its own hurt, fall and use sounds.  Nothing is heard from the void in the recorded run because the observer was 80 blocks away.  `sql/838_sounds.sql` has the functions and the layout; the block sound types come from the jar (`tools/gen_sounds.sh`).  Not modelled: step and jump sounds (client side), `small_fall` for falls without damage, drowning and fire sounds beyond the type names, swimming, the levelup sound.

## Cost per tick

`tests/bench/game/run.sh`-style load (500 players, 100 x 100 chunk area, all moving, `mc.tick()`, 80 measured ticks per run, `mc.play_in_work` truncated once a second like
`mc.server_tick` does: without it the dead pages of that queue make every scan slower round after round and the numbers drift), the baseline `mc.tick_core` of `sql/430` and
the survival one alternated three times on a shared 4-core machine (load average 0.5 to 0.9):

| Round | Tick average without survival | with survival | Difference | Survival steps alone (measured inside the tick) |
|---|---|---|---|---|
| 1 | 35.1 ms | 39.6 ms | +4.5 ms | 2.4 ms (p95 3.9) |
| 2 | 35.5 ms | 37.6 ms | +2.1 ms | 2.3 ms (p95 3.9) |
| 3 | 32.6 ms | 34.9 ms | +2.3 ms | 2.0 ms (p95 2.3) |

So the survival core costs about **2 ms per tick, 6 to 7 % of the sparse 500-moving-player tick** (the table in `GAME.md` says about 40 ms for that load; this run's baseline is
33 to 36 ms).  That is a measurable rise, not none.  Where it goes with nobody hurt, hungry or falling: the snapshot of the survival players' positions before the movement
(0.4 ms), the comparison with the positions after it (0.5 ms: a hash join of the 500-row snapshot; index probes were 0.8 ms), one scan of the online players that finds
everybody with something to do in the entity phase (0.3 ms; the steps then run on that list or not at all), the rest is function-call overhead.  What was tried and
kept: one look at the tick's input instead of one per question (each `EXISTS` on a bloated queue cost 1.2 ms in the first measurement, 6 ms in all), the id-list entity phase
(the six steps cost 2.0 ms when each scanned the table), `enable_nestloop = off` for the move comparison.  A subscript-indexed snapshot (no join) measured 0.2 ms instead of
0.5 ms but needs dense entity ids; not done.  Players who are hurt, hungry, falling or using an item cost more, per player and tick, and only while it lasts (a regenerating
player is one row update per tick).  The batched tick is unaffected because it does not run the survival steps.
