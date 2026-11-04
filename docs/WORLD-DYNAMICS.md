# World dynamics: scheduled ticks, fluids, falling blocks, block support, random ticks (SQL)

Files `sql/880`-`sql/887`, tests `tests/sql/880_dynamics.sql`, the comparison with a real vanilla server `tests/e2e/dyn_probe.py`, reference data derived from the jar by
`tools/gen_dynamics.sh` (`tools/java/DynDump.java`) and loaded by `tools/load_dynamics.py`.  Everything is on by default (`dbcraft.dynamics = on`) and costs one index probe per tick
when nothing is due and nobody is online (0.07 ms measured).  Without the derived data (`dyn_states.tsv`) the whole subsystem is off and the database behaves as before.

## What was built

| Piece | Where | Vanilla source it follows |
|---|---|---|
| Scheduled-tick queue as rows: `mc.block_tick (dimension, x, y, z, kind, type, due, prio, seq)`, one row per pending tick, unique on (position, kind, type) so scheduling a pending tick again is ignored, ordered by (priority, seq), block ticks before fluid ticks, ticks only in chunks inside the simulation distance of an online player, the rest wait | 880, 885 | `LevelTicks`, `LevelChunkTicks`, `ScheduledTick` (`DRAIN_ORDER`, `INTRA_TICK_DRAIN_ORDER`), `ServerLevel.tick` (time is advanced, then block ticks, then fluid ticks, then the chunk source: random ticks and the block broadcast, then entities) |
| Water and lava: `getNewLiquid`, `spread`, `spreadToSides`, `getSpread` with the slope search (`getSlopeDistance`, reach 4 for water, 2 for lava, 4 in the Nether), `isWaterHole`, source conversion for 2 sources over a solid block or a source (gamerules `water_source_conversion` true, `lava_source_conversion` false), delays (water 5, lava 30 / 10 in the Nether, lava's random x4), falling fluid, `canPassThroughWall` with the **collision shapes** (full blocks, slabs, stairs, fences, trapdoors ... through `Shapes.mergedFaceOccludes`, precomputed for all 338 shapes), waterlogging (`LiquidBlockContainer.placeLiquid`: only still water, only into a dry block), lava over water makes stone, water beside or over lava makes obsidian (source) or cobblestone, soul soil + blue ice makes basalt, the `fizz` level event | 882, 883, 884 | `FlowingFluid`, `WaterFluid`, `LavaFluid`, `LiquidBlock` (`onPlace`, `neighborChanged`, `updateShape`, `shouldSpreadLiquid`) |
| The neighbour-update cascade of `Level.setBlock` (flags 3): the new state's `onPlace` (for **every** state change, not only a block change: `LevelChunk.setBlockState` has no such guard), then `neighborChanged` on the six neighbours in the order W E D U N S, then `updateShape` in the order W E N S D U, depth first (the order of `CollectingNeighborUpdater`), which fixes the order ticks are scheduled in and so the order they run in | 884 | `Level.markAndNotifyBlock`, `NeighborUpdater.UPDATE_ORDER`, `BlockBehaviour.UPDATE_SHAPE_ORDER`, `LevelChunk.setBlockState` |
| Gravity: sand, red sand, gravel, suspicious sand and gravel, anvils, concrete powder (every `FallingBlock`): tick scheduled when placed and when a neighbour changes (delay 2), the block leaves its cell when the cell below is free (air, fire, a liquid, a replaceable block), **lands after the fall time of the entity** (start 0.01 above the cell, -0.04 per tick then x0.98, doubles: 7 ticks for 1 block, 17 for 5, 24 for 10), a block already on its way to a cell makes the next one land on top, concrete powder stops in the first cell with water and turns to concrete, the landing is announced like the entity does (`block_update` and `add_transient_block` to those who see it) and the block change one tick later (the entity phase follows the broadcast) | 884, 885 | `FallingBlock`, `FallingBlockEntity.tick/fall`, `ConcretePowderBlock` |
| Block support: torches (standing and wall), plants of the `VegetationBlock` family by the `supports_*` block tags (flowers, grass, saplings, crops on farmland, dead bushes ...), both halves of doors and tall plants, carpets, ladders, buttons and levers, pressure plates and rails, standing and wall signs and banners: when the support goes the block is destroyed (a *loud* event: the broadcast sends level event 2001 and the block change), leaving its fluid | 883, 886 | `canSurvive` / `mayPlaceOn` / `updateShape` of the classes; the rules were read from the bytecode and are listed in `sql/886` |
| Random ticks: `randomTickSpeed` (gamerule, default 3) uniformly random positions per section of every section that holds a randomly ticking block; the hits run: grass block and mycelium (spread to dirt with light 9, die to dirt), crops (the `getGrowthSpeed` formula with the `grows_crops` tag, farmland moisture, neighbours of the same crop), farmland (moisture, dry, back to dirt), saplings (stage 0 to 1) | 887, 884 | `ServerLevel.tickChunk`, `SpreadingSnowyBlock`, `CropBlock`, `FarmlandBlock`, `SaplingBlock` |

## How it is built

* **The engine** (`mc.dyn_run`, sql/884) runs a list of work items (fluid tick, block tick, random tick, a change from outside, a landing) one after another against a **private copy of
  the world**: the sections it can touch decoded into one int4 array (`mc.dyn_secs`; decoded sections are cached per chunk version in `mc.dyn_sec_cache`), reads are array
  subscripts (0.1 us), writes array assignments, and every later item sees the earlier ones' changes, as in vanilla.  At the end ONE `mc.set_blocks` writes the changes and one
  insert queues the new ticks.  So per tick: the cost is the number of due ticks times about 0.1-0.5 ms, not a function call per block read.
* **The reference data** is *read from the jar*, not typed in: `tools/java/DynDump.java` boots the registries the way the data generator does and asks every one of the 35,723 block
  states for its class chain, `isRandomlyTicking`, fluid state, `isSolid`, `canBeReplaced`, light dampening, face sturdiness and **collision shape**, plus
  `Shapes.mergedFaceOccludes` for all pairs of the 338 distinct shapes (69,038 occluding pairs).  Nothing is simulated.  The block tags come from the datapack rows the client's tag packet is built from.
* **Block changes from outside** (a player, a command, SQL) are noticed by a statement trigger on `mc.block_event` (`mc.dyn_on_events`) and handled **inside the same statement**, like
  vanilla's `setBlock`: a torch placed on nothing is not removed (vanilla keeps it until a neighbour changes), a torch whose support is removed is gone before the call returns.
  Cells that are not near anything dynamic are filtered with one section read per neighbour, so an ordinary building edit costs 0.2 ms more.
* **`mc.tick_core`** gets one line, `perform mc.dyn_step(cur);` (sql/837, after the visibility refresh).  `mc.dyn_step` is wrapped in an exception handler: a failure rolls back that
  step, is recorded in `mc.error_log` and does not stop the tick.
* **Quiet writes.**  Vanilla's `setBlock` sends no break effect; only `destroyBlock` does.  The engine's writes are re-recorded as one-position `cells` events (which the broadcast
  never gives a level event 2001); only support breaks stay `block` events.
* Settings: `dbcraft.dynamics` (on/off), `dbcraft.dynamics-max-ticks` (4,000 per kind per tick; vanilla's limit is 65,536), `dbcraft.random-tick-interval` (4: random ticks run every 4th
  tick with 4 ticks' draws), `dbcraft.random-tick-players` (4), `dbcraft.random-tick-max-hits` (6 per tick), the gamerules `minecraft:random_tick_speed`,
  `water_source_conversion`, `lava_source_conversion` in `mc.game_rule`.

## Verified against the real vanilla 26.3 server

`tests/e2e/dyn_probe.py`: a scripted client joins the real server (RCON; `/tick freeze`, then `/tick step 1` per step; the clock is polled until the step ran) and records every
`block_update`, `section_blocks_update` and `level_event` after every tick; the same scenario runs on dbcraft (the game clock moved by hand, `mc.dyn_step`, `mc.broadcast_block_events`,
the packets of a fake connection read from `mc.play_out`).  `compare` requires **each tick's packets to be equal, entry by entry, byte for byte** (packets of different chunks as a
multiset: vanilla sends them in hash-set order).  12 scenarios, 800+ ticks:

| Scenario | Ticks | Result |
|---|---|---|
| water on open ground (the 113-block diamond) / on a ledge (falls, then spreads) / next to a pit (shortest way down) | 60 each | identical |
| two sources and a gap (source conversion) | 40 | identical |
| water around a full block, a slab, stairs, a fence, a trapdoor, top and bottom slabs | 60 | identical |
| lava on open ground (30 ticks per step, reach 2) | 130 | identical |
| lava next to water (obsidian, cobblestone) / lava falling onto a water source (stone) | 100 / 80 | identical |
| sand, gravel, red sand, a stack of three blocks, falling 5 and 10 blocks | 80 | identical, including the landing tick and the block that lands on top of another |
| concrete powder falling into flowing water and a water source (stops at the surface, turns to concrete) | 80 | identical |
| a column of sand losing its floor (each block leaves 2 ticks after the one below) | 60 | identical |
| a torch, poppy, tall grass (both halves), door (both halves), carpet, wall torch, ladder, button, wheat on farmland, sign: each loses its support, then the top half of the tall grass is removed | 24 | identical, including the 22 packets with the level event 2001 of every break |

Things the comparison taught (each was a real bug found by it, all fixed): `onPlace` runs for every state change (a flowing fluid schedules its own tick *inside* `setBlock`, so the tick
order of a draining lake differs otherwise); ticks scheduled during a drain must not see ticks that were already taken out of the queue; the quiet writes; concrete powder stops at the first
water cell; blocks falling in the same column lands one above the other; the entity phase comes after the broadcast; vanilla keeps broadcasting while frozen so the late section update appears
in the same recorded step.  RCON commands and packet-borne edits differ by one tick in when a scheduled tick is due (a command runs before the world tick); dbcraft's SQL edits match the command convention
the probe uses.

In SQL (`tests/sql/880_dynamics.sql`, 47 checks): data consistency, `mc.dyn_secs` against `mc.get_block`, queue rules, the diamond, source conversion and its gamerule, lava reactions,
walls and waterlogging, simulation range (a tick waits while nobody is near and runs when a player comes), fall times, columns of sand, concrete powder, every support rule, `dbcraft.dynamics = off`,
the random-tick statistics (grass spreads, does not spread at midnight, dies under stone, wheat grows at the formula's rate, farmland stays wet near water) and the idle cost.

## NOT verified against vanilla, not modelled, honest list

* **Random ticks are statistical and their rules were read from the bytecode, not compared with a vanilla run.**  The distributions (rate of grass spreading, crop growth) were checked against the
  formulas, not against measurements of the real server.  Light is the engine's heightmap model: open sky is 15 less the sky darkness (formula of `Level.updateSkyBrightness`, assuming the classic
  day cycle: 26.3 drives time with clocks that were not checked), nothing else gives light (no torches), water and leaves do not attenuate.  Crops and mushrooms ignore the light condition for *survival*.
* **Bounded cost, so below vanilla's rate at scale**: only the areas of 4 random players are random-ticked each tick, runs happen every 4th tick, at most 6 hits per tick.  With few players that is
  nearly vanilla's rate (the cap bites in dense grass: a flat grass plain near one player yields about 27 hits per tick in vanilla and 6 here, so grass spreads about 4 times slower there).
* Not implemented: **leaf decay and the `distance` of leaves, tree growth from saplings** (only the stage advances), sugar cane, cactus, bamboo, kelp, vines, mushrooms, nether plants, ice and snow
  melting and weather snow/ice, fire and lava starting fire, bubble columns (soul sand / magma under water), pistons and redstone, copper oxidation, budding amethyst, dripstone, sponges.
  **Shape properties are not updated** by `updateShape` (fences, walls, panes and stairs do not connect when a neighbour appears: they keep the placed state), and placement is still default-state only.
* **No items drop**: blocks destroyed by water, by lava or by losing support drop nothing (the entity module has no loot tables); a falling block that cannot land (its cell is taken) is lost instead of
  dropping an item.  **There is no falling-block entity**: the block leaves its cell and *appears at the landing cell after the vanilla fall time*; a client sees no sand falling (the packets at the landing
  are vanilla's).  The landing cell is found at the start of the fall (a floor built under it later is not noticed; the block lands in the cell it computed or is lost if that is taken); partial collision
  shapes under a falling block (slabs, snow layers) are treated as full blocks.
* Chunks do not unload here, so a tick that became due in an area nobody was near runs at once when a player arrives (vanilla keeps the remaining delay of an unloaded chunk).  Ticks of a chunk never run
  without an online player, also near the world spawn (vanilla's spawn chunks tick).  Reading a chunk that does not exist counts as a solid wall (vanilla would generate it).
* Fills (`kind = 'cells'` events) only start dynamics for the cells whose new state is dynamic (a fluid, a falling block, a support-dependent block); the neighbours of a filled area are **not** notified (a
  torch beside a hole made with `/fill` stays).  Statements that change more than 64 cells are filtered by the cells' own states only.
* `mc.server_tick_batched` (sql/389) does not call `mc.tick_core` and therefore runs no dynamics.
* Level events other than the break effect (2001) and the lava fizz (1501) are not sent; no sounds.  The fizz was not part of the recorded comparison's KEEP set beyond the packet counts shown.
* The broadcast's behaviour that mc.set_block of a removal sends a break effect (a documented deviation from `/setblock`) is unchanged for edits by players and commands.
* Simulation range: a chunk ticks when an online player's chunk is within `simulation-distance` (square).  Vanilla's block-ticking range (`DistanceManager.inBlockTickingRange`) was not measured; it may be one chunk wider.
* Players have no dimension column, so dynamics run for the world's default dimension only.

## Cost

See the end of this file for the measured numbers (500 players, nothing scheduled; a large active fluid).
