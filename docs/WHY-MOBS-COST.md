# Why mobs cost what they cost (DRAFT, numbers being filled in)

This file is being written in steps; the raw measurements are in docs/why-mobs-results.txt and docs/why-mobs-vanilla.jsonl.

## What vanilla does for the same work (read from the 26.3 jar with `javap -c -p`)

Per mob and tick, in the order the server runs them (`ServerLevel.tick`, `ChunkMap.tick`, `Mob`, `LivingEntity`):

1. **Is the mob ticked at all?**  `ServerLevel.tick` walks the entity tick list (entities of chunks that are at entity-ticking level).  For every entity in it:
   `entity.checkDespawn()` (a `Level.getNearestPlayer(entity, -1)` scan of the players, every tick, for every mob), then `DistanceManager.inEntityTickingRange(chunk)`; only inside it
   (a chunk within the simulation distance of a player, 10 chunks by default) the entity is ticked.  A mob in a chunk that no player is within 10 chunks of costs **nothing at all**
   (not in the list, or skipped before `tick`).  That is the "activation by chunk status" of vanilla; dbcraft has no such notion: a mob exists and is simulated (lazily, but it is) wherever it is.
2. **`Mob.tick` / `LivingEntity.tick` / `Entity.baseTick`**: tick counters, fire / water / lava / fluid state checks, block effects (`applyEffectsFromBlocks`), frost, invulnerability
   counters; every 5th tick `updateControlFlags`.
3. **`Mob.serverAiStep`** (called from `LivingEntity.aiStep`): `noActionTime++`; `Sensing.tick`; **every second tick** (`(tickCount + entityId) % 2 == 0`, or tickCount <= 1) `targetSelector.tick()` and
   `goalSelector.tick()`, otherwise only `tickRunningGoals(false)` (the running goals that need an update every tick); then `navigation.tick()`, `customServerAiStep`, `moveControl.tick()`,
   `lookControl.tick()`, `jumpControl.tick()`.  `GoalSelector.tick` first stops the running goals that cannot continue, then asks `canUse()` of **every goal that is not running** (a cow has eight:
   `FloatGoal`, `PanicGoal`, `BreedGoal`, `TemptGoal`, `FollowParentGoal`, `WaterAvoidingRandomStrollGoal`, `LookAtPlayerGoal`, `RandomLookAroundGoal`; `TemptGoal.canUse` calls
   `ServerLevel.getNearestPlayer(...)` unless it is cooling down; the look goals draw a random float first).
4. **`RandomStrollGoal.canUse`** (cows: `WaterAvoidingRandomStrollGoal(1.0)`, interval 120): `false` when `noActionTime >= 100` (!), else `random.nextInt(reducedTickDelay(120)) == 0`
   (= 1 in 60 per evaluation, every second tick: a stroll every 120 ticks on average); the target is a random point within 10 blocks horizontally and 7 vertically (`LandRandomPos.getPos(mob, 10, 7)`,
   7 times out of 1000 with a different 15-block variant in water), reached by **A\* pathfinding** (`PathNavigation.createPath` -> `PathFinder.findPath`, a node budget from the follow range).
   `PathNavigation.tick` then follows the path every tick, `MoveControl` turns the wanted position into `setSpeed` / `setZza`, `LookControl` into head and body rotation.
5. **`LivingEntity.aiStep`**: interpolation, the water / lava / jumping checks (`getFluidHeight` twice), **`travel`** (`Entity.move` with the block collisions of the box: `Entity.collide`,
   `getBlockCollisions`, step height, friction of the block below), `applyEffectsFromBlocks`, frost, **`pushEntities`** (`Level.getPushableEntities(entity, box)`: an entity query in the chunk
   sections for every mob every tick; each overlapping mob is pushed, the "cramming" check at more than 24 overlapping), water damage for the water-sensitive.
6. **Tracking** (`ChunkMap.tick`): for every tracked entity, a section-change test (`SectionPos.of(entity)` against the last one, and `updatePlayers` of the entities that moved to another section or
   of the players that moved), and `ServerEntity.sendChanges()` for the entities in entity-ticking range: `updateDataBeforeSync`, a passenger comparison, **work only when
   `updateInterval.test(tickCount)`** (interval 3 for everything but items 20 and players 2) **or the synched data is dirty**; then the quantised position delta (`VecDeltaCodec`), rotation (`Mth.packDegrees`),
   `trackDelta` (every type except players: a velocity change of more than 1e-7 squared sends a `set_entity_motion`), a position sync every 400 ticks.  Packets are encoded and written to every
   tracking connection by the network threads (which is why the viewer's traffic is not in the main thread's number: 2,000 cows in view sent the viewer 148 KB/s, see below).

What a mob that nobody can see costs in vanilla is therefore items 1-5 minus the tracker (6): a few dozen field reads and writes per tick in JIT-compiled code, one goal pass every second tick that
fails 59 times of 60 (and, beyond 32 blocks from every player, fails at once, see "Walking share"), and a stroll's A\* once per 120 ticks on average.

## What dbcraft does NOT model (so how much of vanilla's cost it does not pay)

| vanilla does | dbcraft |
|---|---|
| A\* pathfinding for every stroll (`PathFinder`, node evaluator reading block states, path following, recomputation) | none: a goal is a straight line (direction and speed drawn from a hash of (id, tick)) |
| the goal system: 8 goals for a cow, `canUse` of all non-running goals every second tick, flags and locks, panic when hurt, tempting by wheat, breeding, following the parent | none: "wander" only (60 % of new goals walk 20-79 ticks, 40 % stand 40-139 ticks) |
| look-around: `LookControl`, `RandomLookAroundGoal`, `LookAtPlayerGoal` (head and body rotation packets, `rotate_head`) | yaw is the walking direction, one `rotate_head` with a rotation change |
| `Entity.move` collision for every mob every tick (block shapes, step-up, edges) | a lane is dead reckoning on a floor proven uniform; the exact sweep (full cubes only, no steps, no slabs) runs only for mobs that cannot get a lane |
| entity-entity collision, pushing, cramming (`pushEntities`: an entity query per mob per tick) | none |
| `set_entity_motion` for every velocity change, `move_entity_pos_rot`, `rotate_head`, ambient sounds (`sound` packets), `entity_position_sync` every 400 ticks, dirty-data sync | `move_entity_pos` / `move_entity_rot` + `rotate_head` at the 3-tick cadence, a sync every 400 ticks; no motion packets, no sounds |
| random ticks, despawn rules (`checkDespawn`: persistence, 128 / 32-block distances, 800-in-1 after 600 ticks idle), spawning by light and biome, breeding, loot, damage, ageing | a 600-tick despawn of mobs nobody sees; the prototype spawner |
| entity ticking range = simulation distance, "activation" by chunk status | every mob row is simulated (lazily when nobody can see it) wherever it is |
