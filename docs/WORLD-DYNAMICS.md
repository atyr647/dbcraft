# World dynamics: scheduled ticks, fluids, falling blocks, block support, random ticks (SQL)

Files `sql/880`-`sql/888` (and `sql/962`, the optional native accelerator of fills), tests `tests/sql/880_dynamics.sql`, the comparison with a real vanilla server `tests/e2e/dyn_probe.py`, the random-tick rates `tests/e2e/rt_rate.py`, reference data derived from the jar by
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
| Random ticks: `randomTickSpeed` (gamerule, default 3) uniformly random positions per section; the hits run: grass block and mycelium (spread to dirt with light 9, die to dirt), crops (the `getGrowthSpeed` formula with the `grows_crops` tag), farmland moisture, saplings (stage 0 to 1, silent: flags 260), **leaf decay** (not persistent leaves at distance 7), **sugar cane** and **cactus** (age, growth, the cactus flower).  Only the cells whose tick can change something are drawn (see "Random ticks" below); statistical, not vanilla's random numbers | sql/886, 887, `tickChunk`, `SpreadingSnowyBlock`, `CropBlock`, `FarmBlock`, `SaplingBlock`, `LeavesBlock`, `SugarCaneBlock`, `CactusBlock` |
| **Leaves** (`LeavesBlock`): `updateShape` of a leaf next to a changed cell schedules a block tick in 1 tick unless the distance it would get is 1 and already shown; the tick sets the distance to the smallest of the six neighbours' distance + 1 (0 for a block of the tag `prevents_nearby_leaf_decay`, its own distance for leaves, 7 otherwise; order DOWN UP NORTH SOUTH WEST EAST, stop at 1) with flags 3, so the change spreads outwards one tick per step; leaves at distance 7 that are not persistent are random-ticking and are removed (water left when waterlogged) | 883, 884, 886, 887 | `LeavesBlock.updateShape / tick / updateDistance / getOptionalDistanceAt / randomTick / decaying` (javap of the 26.3 jar) |
| **Sugar cane and cactus**: `canSurvive` (cane: cane below, or a block of `supports_sugar_cane` with water or frosted ice next to it; cactus: no solid block or lava at the four sides, cactus or `supports_cactus` below, no liquid above); every neighbour update asks it and schedules a block tick in 1 tick, the tick destroys the plant (break effect 2001); a column breaks from the bottom, one block a tick.  Random tick: with air above, age + 1 with flags 260 (not even the clients are told), at age 15 and fewer than 3 blocks a new block above (cactus: at age 8 a cactus flower on top with probability 0.1, 0.25 from height 3) | 883, 884, 886, 887 | `SugarCaneBlock`, `CactusBlock` |
| **A time budget per tick and a work queue** (`dbcraft.dynamics-tick-budget-ms`, default 40; 0 = vanilla's behaviour): the due ticks are taken in slices sized by the measured cost per tick, the ones that do not fit stay queued in vanilla's order (due time, priority, sequence) and run first in the next tick; the reactions of a fill that do not fit go to `mc.dyn_work` | 880, 884, 885 | not in vanilla (it only caps at 65,536 ticks a tick: `LevelTicks.tick`) |

## How it is built

* **The engine** (`mc.dyn_run`, sql/884) runs a list of work items (fluid tick, block tick, random tick, a change from outside, a landing) one after another against a **private copy of
  the world**: the sections it can touch decoded into one int4 array (`mc.dyn_secs`; decoded sections are cached in `mc.dyn_sec_cache`, valid for the chunk version recorded in `mc.dyn_sec_ver`, and the engine updates the cache with its own change log after it writes, so a flow does not decode its sections again every tick), reads are array
  subscripts (0.1 us), writes array assignments, and every later item sees the earlier ones' changes, as in vanilla.  At the end ONE `mc.set_blocks` writes the changes and one
  insert queues the new ticks.  So per tick: the cost is the number of due ticks times about 0.1-0.5 ms, not a function call per block read.
* **The reference data** is *read from the jar*, not typed in: `tools/java/DynDump.java` boots the registries the way the data generator does and asks every one of the 35,723 block
  states for its class chain, `isRandomlyTicking`, fluid state, `isSolid`, `canBeReplaced`, light dampening, face sturdiness and **collision shape**, plus
  `Shapes.mergedFaceOccludes` for all pairs of the 338 distinct shapes (69,038 occluding pairs).  Nothing is simulated.  The block tags come from the datapack rows the client's tag packet is built from.
* **Block changes from outside** (a player, a command, SQL) are noticed by a statement trigger on `mc.block_event` (`mc.dyn_on_events`) and handled **inside the same statement**, like
  vanilla's `setBlock`: a torch placed on nothing is not removed (vanilla keeps it until a neighbour changes), a torch whose support is removed is gone before the call returns.
  It first asks the palettes (below): an edit with nothing reactive or random-ticking near it costs the statement 0.04 ms.  Otherwise cells not near anything dynamic are filtered with one section read per neighbour.  The trigger reads the sections fresh (`mc.dyn_nocache`): a `/fill` records the events of a chunk before it bumps the chunk's version, and a cached section can be older than the rows (this once dropped the fluid ticks of every fill after the first whose sections were cached, and of every chunk but the first of a multi-chunk fill).
* **`mc.tick_core`** gets one line, `perform mc.dyn_step(cur);` (sql/837, after the visibility refresh).  `mc.dyn_step` is wrapped in an exception handler: a failure rolls back that
  step, is recorded in `mc.error_log` and does not stop the tick.
* **Quiet writes.**  Vanilla's `setBlock` sends no break effect; only `destroyBlock` does.  The engine's writes are re-recorded as one-position `cells` events (which the broadcast
  never gives a level event 2001); only support breaks stay `block` events.
* Settings: `dbcraft.dynamics` (on/off), `dbcraft.dynamics-dimensions` (comma-separated list, default `minecraft:overworld,minecraft:the_nether,minecraft:the_end`: block edits in any
  other dimension are stored but nothing reacts to them; the SQL tests use private `dbcraft:*` dimensions to test raw storage, and saplings placed in mid-air there would otherwise be
  dropped on the next neighbour update, exactly as in vanilla), `dbcraft.dynamics-max-ticks` (65,536 per kind per tick: **vanilla's own limit**, read in the jar: `ServerLevel.tick`
  passes 65536 to `LevelTicks.tick`, whose drain stops there and leaves the rest queued in order, which is what the `limit` of `mc.dyn_run_due` does), `dbcraft.random-tick-interval`
  (4: random ticks run every 4th tick with 4 ticks' worth of draws), `dbcraft.random-tick-max-hits` (6 per tick), `dbcraft.random-tick-build-ms` (0.3: CPU per tick, on average, the maintenance of the lists may use), `dbcraft.random-tick-quiet` (100: ticks a chunk must be left alone before its list is rebuilt), the gamerules `minecraft:random_tick_speed`, `water_source_conversion`, `lava_source_conversion` in `mc.game_rule`.
* **Random ticks (sql/887).**  Vanilla draws `randomTickSpeed` positions per section per tick and runs the tick of the block it hits; the tick of most blocks is a no-op (a grass block
  with no exposed dirt around it, ripe wheat, wet farmland, a sapling at stage 1).  dbcraft keeps, per section, the list of the **active** cells: those whose tick can change something
  (`mc.dyn_rt_build`: grass that dies or has exposed dirt in its 3 x 5 x 3 spreading volume, crops and saplings that can still grow, farmland that is not fully wet with water in reach), in
  `mc.dyn_rt_sec` (only sections with an active cell have a row).  A run (every 4th tick) is: the hit count is Poisson with mean `3 * speed * interval * active cells in range / 4096`, each hit
  lands in a section with probability proportional to its active cells and at a uniformly random one of them: the same distribution as vanilla's draws on the active cells, and skipping the
  no-ops changes nothing.  **O(hits), one probe of one table when nothing is active.**  All online players' areas are served.  A test runs 40 random ticks on each of 665 inactive cells (grass,
  wheat, farmland, saplings across chunk borders) and requires that nothing changes.
* **Keeping the lists current (sql/885, 887) is bounded work, not a rebuild on every edit.**  The cost of the first version was not the hits but the lists: every chunk built 4 at a time every
  4th tick at 50 ms each, 100 to 240 ms spikes while a pregenerated world was being listed, and again after every fill.  Now:
  * The event trigger asks the **palettes** first.  The sections the events are in (and the face neighbours, when a block event is on that face, always for a fill) and the old and new
    states of the events are looked up by name in `mc.dyn_state` (`react`: a state a change next to it can make react; `tickc`: a class of random tick this engine implements).  Nothing of
    either kind: the statement returns without reading the engine's arrays.  Only a random-ticking kind queues lists (`mc.dyn_rt_dirty`: the chunk, its neighbours within 4 cells of a border,
    stamped with the game time, newest first); only a reactive kind runs the reaction (the old per-cell code).
  * A queued chunk is built only after it has been **left alone for `dbcraft.random-tick-quiet` ticks** (100: a burst of edits is built once, afterwards) and by one chunk at a time, whose
    CPU time is **paid back in ticks**: the maintenance (`mc.dyn_rt_maintain`) uses `dbcraft.random-tick-build-ms` (0.3 ms) per tick on average, a build that cost 10 ms makes the next 33 ticks
    wait.  A pregenerated world of 7,000 chunks is listed in the background over about half an hour; nothing queued costs one probe per tick.
  * **A neighbourhood is hashed** (`mc.dyn_rt_memo`: the stored rows of the chunk's nine columns): when an identical one is known to have no active cell, so has this chunk.  A flat world is one
    neighbourhood: its chunks cost 1.4 ms, not a build.  Sections made of 16 uniform layers (a flat world, a floor, a fill) are decoded without looking at 4,096 entries
    (`mc.dyn_decode_layered`).  What remains of a real build is 8 to 12 ms (the nine columns' decoded sections, a pass over the candidates, the border cells), once per edit burst.
  * The lists are patched per cell after a few single-block edits (`mc.dyn_rt_patch`, below) and rebuilt per chunk after anything bigger (fills, the engine's own writes, a chunk without a list): a neighbouring chunk's list is rebuilt
    when the edit is within 4 cells of it.
* **The engine's own cost (this round, sql/882-885, 888).**  A profile with `track_functions = all` showed what the item loop was really paying for: LANGUAGE sql helpers called with a computed
  argument (`mc.dyn_ftype(mc.dyn_fstate(...))`, `mc.dyn_is_src_of(mc.dyn_fstate(fl, fa, mc.dyn_at(...)), fam)`, `mc.dyn_hold_specific(fl, below, mc.dyn_ftype(nb))`) are **not inlined** (the planner refuses
  when a parameter used more than once is an expensive expression) and then parse and plan their body again in every call: 290,000 such calls in the 40 x 40 burst, 3 to 5 us each.  They are
  now written on the flags in place or called with variables (inlined, 0.1 us); the ops of a cascade are written forward at the top of one stack as *frames* (no array per reaction, no
  reversed copy), and a schedule that cannot be preceded by another op of the same reaction is executed at once instead of being pushed and popped.  `mc.cells_positions` (the
  broadcast expands every one-cell event of the engine with it) has a path for sparse maps (19,000 calls at 40 us before, a few us now).  All due ticks of a tick run in **one** engine
  call in vanilla's global order (the previous code split them into groups of touching chunks, which gave the ticks they scheduled their order numbers group by group and drew the engine's
  random numbers in another order than vanilla does); `dbcraft.dynamics-single-run-chunks = 0` gives the old grouping back (the equivalence tests against the starting commit use it).
* **Time budget, deadline, work queue.**  `mc.dyn_run_due` takes the due ticks of one kind in vanilla's order (`LevelTicks.DRAIN_ORDER`: due time, priority, order of scheduling; the previous code
  ordered by priority and sequence only, which is the same until ticks are deferred) in slices sized by a smoothed cost per tick; `dbcraft.dynamics-tick-budget-ms` (default 40, 0 = none) is the wall-clock
  time a tick may spend on them.  The engine takes a deadline too (`mc.dyn_run`, checked every 16 items): the ticks that were taken but not run go back into the queue as they were (an equal tick
  scheduled meanwhile loses to the original: in vanilla it would have been ignored as already pending).  **Every tick runs at least one slice of each kind** (a first version let the block pass use
  the whole budget and starved the fluid ticks for hundreds of ticks: found by a random test, fixed).  The reactions of a `/fill` (the trigger of `mc.block_event`) get the same budget: what does not fit
  is queued in `mc.dyn_work` with the game time of the fill (the ticks it schedules are due relative to that time) and run in the following ticks; the engine puts the cells of a fill's
  placements back to their old state for the whole list, so a run that stops early gives the items it did run the world a complete run would have shown them.  **This deviates from vanilla only for a
  tick that costs more than the budget**; vanilla itself takes the whole burst in one tick (and would stall for that long).  The 13 vanilla scenarios and the equivalence tests run with budget 0.
* **Silent writes.**  `setBlock` with flags 260 (age of sugar cane and cactus, the stage of a sapling: `SugarCaneBlock.randomTick`, `CactusBlock.randomTick`, `SaplingBlock.advanceTree`) does not even tell the
  clients; the engine's write mode 3 deletes the block events of those cells after `mc.set_blocks`.  (The sapling stage step was sent as a block update before: a difference found while reading the
  bytecode for the new families.)
* **Random-tick lists patched, not rebuilt (sql/887 `mc.dyn_rt_patch`).**  A statement of up to 24 single-block edits in chunks that have lists re-evaluates the cells around each edit
  (1 cell horizontally, 2 below to 3 above; farmland within 4 cells of an edit that places or removes a fluid) with the one-cell rule `mc.dyn_rt_hit` and adds them to or removes them from their section's list
  at once; the chunk is not queued for the 100-tick-delayed rebuild.  The test patches 150 random edits next to grass, dirt, farmland, water, crops and saplings and requires every list to equal a fresh
  `mc.dyn_rt_build` of the chunk.  One edit costs about 0.05 ms more in the statement; a rebuild is 4 to 8 ms.  (Fills and engine writes still queue the chunk.)
* **Native accelerator for the first fill of a shape (sql/962, `native/dbcraft_set`, optional).**  See [PERF-WORLD2.md](PERF-WORLD2.md) "Cold fills".
* **Cheaper fluid ticks (sql/882, 884, 888).**  The slope search is skipped when no hole can exist (every cell below the search diamond is a full block: the common case, a flow over a
  floor), the wall / hole / replaceable predicates are inlineable SQL, the pending-tick check of a run is an open-addressing hash set instead of a linear scan, the reaction of a water
  neighbour to a change is computed in place, and `mc.cells_positions` (sql/850, called once per recorded change by the broadcast) visits only the non-zero bytes of the bit map
  (override listed in sql/OVERRIDES.txt).

## Verified against the real vanilla 26.3 server

`tests/e2e/dyn_probe.py`: a scripted client joins the real server (RCON; `/tick freeze`, then `/tick step 1` per step; the clock is polled until the step ran) and records every
`block_update`, `section_blocks_update` and `level_event` after every tick; the same scenario runs on dbcraft (the game clock moved by hand, `mc.dyn_step`, `mc.broadcast_block_events`,
the packets of a fake connection read from `mc.play_out`).  `compare` requires **each tick's packets to be equal, entry by entry, byte for byte** (packets of different chunks as a
multiset: vanilla sends them in hash-set order).  **Re-run after the cost work of this round (the engine's loop, the single run, the budget set to 0): the 13 scenarios below, against a fresh vanilla world: ALL IDENTICAL.**  13 scenarios, 900+ ticks (and 4 more below):

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

**The burst** (`water_layer`, the 13th scenario: 16 x 16 water sources placed by one `/fill`, 256 fluid ticks in one tick, falling columns, a sheet that spreads 7 blocks into the neighbouring
chunks, 60 ticks, 73 packets): **identical in all 60 ticks**.  It found that a `/fill` is not a row of `setBlock`s: vanilla places every block with flags 2 | 256 (onPlace and updateShape run, no
neighbour update), collects them, and calls `updateNeighboursOnBlockSet` for each of them AFTER all are placed (`FillCommand`, read in the bytecode).  The engine now does the same for the events
of a fill (items of kind 9 and 10, sql/884): the cells are put back to their old state in its private copy and set to the new one when their turn comes, so an early block's updateShape does not
see the blocks that come after it, and the fluid ticks are scheduled in placement order.  Before, the first rows of the layer scheduled their neighbours early and the entries inside three of the
60 packets were in a different order.  A fill across several chunks is still handled chunk by chunk (its events are recorded per section, one trigger run each), which vanilla does in one sweep.
The probe rebuilds the floor at the start of each run and a vanilla world must be fresh for each recording (a recorded flow leaves pending ticks).

**Leaves, sugar cane and cactus, against the real server too** (`dyn_probe.py`, the same method; all 17 scenarios were recorded in one run from a fresh vanilla 26.3 world and compared with one run of dbcraft on a fresh
database: **17 of 17 identical in every tick**, full output in `docs/dyn-probe-results.txt`): `leaves_distance` (a blob of leaves in default state around a trunk settles
to its distances, the top of the trunk is removed and put back: the distance wave moves one tick per step; 54 ticks, 84 packets), `leaves_persistent` (half of the blob persistent: 28 ticks, 42 packets),
`cane_breaks` (cane on sand with water beside it and on dirt: removing the sand, the water, and putting a stone next to a cane, and removing the dirt: 24 ticks, 25 packets) and `cactus_breaks` (a solid block beside it, water on it,
the sand under it removed: 20 ticks, 18 packets): **every packet of every tick identical** (the packets are entries in set order and level events 2001).  A vanilla server must be fresh for each recording (an earlier recording of `leaves_persistent` showed 0 packets because the server had saved the scripted player floating in mid-air and kicked it), and the scenarios
run in sequence (a recorded flow leaves pending ticks that the next scenario's steps run: the first four steps of `sand_support_removed` show the tail of `water_layer`); the four new scenarios therefore come last.

**Random-tick rates** (`tests/e2e/rt_rate.py`, results in `docs/dyn-rates-results.txt`): both servers run the same set-up and the same number of ticks at `random_tick_speed 3`, vanilla with `/tick sprint`, dbcraft with
`mc.dyn_step` in a loop; the outcomes are compared as fractions with a three-standard-error rule.

| after N ticks | vanilla | dbcraft | z |
|---|---|---|---|
| sugar cane, 100 plants, 21,000 ticks: grew a second block | 51 | 53 | -0.3 |
| cactus, 100 plants, 21,000 ticks: grew a second block | 43 | 43 | 0.0 |
| cactus: flowered (age 8, probability 0.1 once per plant) | 17 | 11 | +1.2 |
| leaves at distance 7, not persistent, 200 of them, 1,500 ticks: still there | 63 | 58 | +0.5 |

(The expected values of the formulas: cane 50 of 100 at this number of ticks, leaves 66.7 of 200.)  Mean age of the plants that did not grow: cane 6.0 / 5.8, cactus 6.6 / 6.7.  **This is the measurement that found the
scheduler's rate bug** (3 times vanilla's draws, see "NOT verified" below).

In SQL (`tests/sql/880_dynamics.sql`, 96 checks): data consistency, `mc.dyn_secs` against `mc.get_block`, queue rules, the diamond, source conversion and its gamerule, lava reactions,
walls and waterlogging, simulation range (a tick waits while nobody is near and runs when a player comes), fall times, columns of sand, concrete powder, every support rule, `dbcraft.dynamics = off`,
the random-tick statistics (grass spreads, does not spread at midnight, dies under stone, wheat grows at the formula's rate, farmland stays wet near water), the lists of active cells (inactive cells never change under 40 random ticks each; the lists are rebuilt after edits and for new chunks), a fill across four chunks, `mc.cells_positions` against the old definition, the layered decode against the entry-by-entry decode, the event trigger doing nothing when nothing near an edit reacts or ticks, and the idle cost.

## NOT verified against vanilla, not modelled, honest list

* **Random ticks are statistical.**  Vanilla's random numbers are not reproduced; the rules were read from the bytecode.  Sugar cane, cactus and leaf decay were compared by RATE with the real server
  (`tests/e2e/rt_rate.py`, table above); grass spreading, crop growth, farmland and saplings still only against the formulas.  **The rate comparison found that the scheduler drew `random_tick_speed * 3` positions
  per section and tick, three times vanilla's `random_tick_speed` (fixed in this round); everything that earlier rounds say about random-tick speeds was three times too fast.**  Light is the engine's heightmap model: open sky is 15 less the sky darkness (formula of `Level.updateSkyBrightness`, assuming the classic
  day cycle: 26.3 drives time with clocks that were not checked), nothing else gives light (no torches), water and leaves do not attenuate.  Crops and mushrooms ignore the light condition for *survival*.
* **Hits per run are capped** (`dbcraft.random-tick-max-hits`, 6 per tick): a very large farm or a long grass edge near players ticks at a lower rate than vanilla's (a random subset of the hits
  runs); with nothing active near the players there is no cap and no cost.  The lists of active cells assume the rules above: a block class added to the engine must be added to `mc.dyn_rt_build`
  too (the test that inactive cells never change is the guard).  An edit that bypasses `mc.block_event` is picked up by a reconcile pass every 1,200 ticks.
* Not implemented: **tree growth from saplings** (the stage advances, a sapling at stage 1 stays: `TreeGrower` needs the tree features' placement and their random draws; not started), bamboo, kelp and other growing
  plants (`GrowingPlantHeadBlock`), vines, mushrooms, nether plants, **ice and snow**: melting needs BLOCK light (`IceBlock.randomTick`, `SnowLayerBlock.randomTick` ask `getBrightness(LightLayer.BLOCK, pos)`), which the current
  light model does not have (nothing gives light), so nothing would ever melt, and freezing / snowfall need weather and biome temperature; the rule is not coded so that it cannot be wrong silently.  When the light
  engine lands, the cell's light should be read through one function (as `mc.dyn_sky_darken` and the heightmap light are read here) and the two classes added to sql/887.  Also not implemented: fire and lava starting
  fire, bubble columns (soul sand / magma under water), pistons and redstone, copper oxidation, budding amethyst, dripstone, sponges, the cactus flower's own behaviour, beehives.
  **Leaves, sugar cane and cactus are implemented, see the table above.**  **Leaves a player places are persistent now** (`LeavesBlock.getStateForPlacement`: `persistent = true`, the distance of the neighbours, waterlogged by the fluid in the cell; a branch added to `mc.place_state` in `sql/890`
  and `mc.leaf_distance_at` in `sql/886`): without it every leaf block a player put down would have decayed like a natural one.  Leaves from an imported world keep what the world says; leaves from `dbcraft:noise` do not exist (no trees).
  **Shape properties are updated only for player placements and breaks** (`mc.shape_neighbours`, sql/890, [WORLD.md](WORLD.md) "Block placement states": fences, glass panes, iron bars, stairs, fence gates, chests; walls are not modelled) and not by the engine here: a fence next to a block that was changed by water, sand, a command or SQL keeps its state.  Placement computes the state vanilla computes for the families listed there.
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

How measured.  **CPU time of the backend (`/proc/<pid>/stat`), not wall clock** (the machine is shared with other builds, load average 10 to 23; wall times were 2 to 4 times CPU), 10 ms
resolution, one transaction per tick as the server does, caches reset before each run.  Vanilla: the real 26.3 server, CPU of its `Server thread` (`/proc/<pid>/task/<tid>/stat`),
`gamerule random_tick_speed 0` against `3` in alternation, and the water layer; its JIT warms up during the first run, so the range of two runs is given.

### A big flow: 40 x 40 water source layer dropped 10 blocks (1,600 sources, 20,592 water cells at the end: the columns stay), 120 ticks

CPU time of the backend (`/proc/PID/schedstat`, nanoseconds), `mc.dyn_step` plus `mc.broadcast_block_events` per tick, one transaction per tick, a viewer in range, `tests/bench/world2/burst.py`; the fills
(nine chunk-aligned `mc.fill` calls) are not part of it.  Vanilla: the real 26.3 server, one `/fill` of 1,600 sources, a scripted client in range, CPU time of the "Server thread" and of all JVM threads from
`/proc/PID/task/*/schedstat` over 7 s (140 ticks) with the same 7 s of idle subtracted, `tests/bench/world2/vanilla_burst.py`.  **Measured on a quiet machine this time (load average 1 to 4 against 10 to 26 for the
numbers this section carried before).**

| | CPU for the 120 ticks | worst tick | ticks over 60 ms |
|---|---|---|---|
| **vanilla 26.3**, Server thread, net of idle (4 repetitions: 0.50 JIT warming up, then 0.23, 0.24, 0.23 s) | **0.23 to 0.50 s** | about 40 ms per tick in the waves (earlier measurement) | |
| vanilla, all JVM threads, net of idle (2.4 warming up, then 0.8, 1.0, 0.5 s: JIT compiler, GC) | 0.5 to 1.0 s warm | | |
| dbcraft at the start of this round (commit 299673a, same machine, 3 runs) | 4.9 to 5.6 s (3.7 to 4.1 s `dyn_step`, 1.2 to 1.5 s broadcast) | 520 to 585 ms | 11 to 18 |
| dbcraft now, budget 0 (vanilla's behaviour, 3 runs) | **2.45 to 2.54 s** (2.15 to 2.21 s `dyn_step`, 0.31 to 0.33 s broadcast) | 240 to 295 ms | 11 |
| dbcraft now, `dbcraft.dynamics-tick-budget-ms = 40` (default), 300 ticks | 5.5 s for the same work (see below) | **70 ms** (60 ms in the engine) | 3 of 300 |

Every dbcraft row ends in the same 20,592 water cells; the world, the queue and every packet of every tick are identical between the starting commit and now (`burst.py` prints checksums; `dyn_equiv.py`: random scenarios
tick by tick).  (Vanilla's figure includes the `/fill` itself, 100 to 200 ms of it; dbcraft's nine fill statements cost 0.2 to 0.4 s of CPU on the connections that issue them, outside the tick: neither side's number is the whole story.)  **dbcraft is 2.1 times cheaper than it was, and still 5 to 11 times vanilla's main-thread CPU (2.5 s against 0.23 to 0.50 s), 2.5 to 5 times vanilla's whole JVM.  The target of this round, at most 3
times vanilla and no tick over 60 ms, is met for the tick (with the budget) and NOT for the total.**

Raw output of these runs: `docs/dyn-burst-results.txt`.

Where the time went (`track_functions = all`, timers inside the engine, in the order they were found and fixed):

* 290,000 calls of LANGUAGE sql helpers that the planner did not inline (see "How it is built"), 3 to 5 us each: 3.3 s to 2.6 s of `dyn_step` with the results unchanged.
* The broadcast expanded every one-cell event of the engine with `mc.cells_positions` (40 us each, 19,000 of them): 1.2 s to 0.33 s of broadcast.
* One engine call per tick instead of one per group of touching chunks, the section needs of the items reduced to the distinct ranges first (10 ms to 2 ms of set-up per call), the due ticks deleted by `ctid`, the
  `due`-only index dropped (a quarter of every tick insert): 2.2 s to 2.15 s.
* What is left of the 2.15 s (per 5-tick cycle of 3,500 items, 40 ms of which are the 1,760 changes' `mc.set_blocks`): item loop 85 ms (24 us an item: two `mc.dyn_new_liquid` calls and about 100 statements), write-back
  62 ms (`set_blocks` 25 to 35, the events' rewrite as quiet ones 8, the insert of 5,000 new ticks into a table with three indexes 27), set-up 10 ms.  The item loop is **sequential by nature**: a tick may read what an earlier
  tick of the same game tick wrote (a fluid reads its four neighbours, the slope search reads 5 cells away), so a set-based pass over all due fluids cannot produce the same packets, and I did not find a conflict test cheap and exact enough to run
  the independent ones set-based (the wave of 1,600 falling columns reads cells their neighbours write in the same tick, though never in a way that changes the result).  **I did not do the set-based redesign the task asked for;
  the per-item cost is what remains.**

**The time budget.**  With `dbcraft.dynamics-tick-budget-ms = 40` the first ticks of the burst take 44 to 70 ms (the first slice of a session has no cost estimate yet) and the later ones 44 to 53 ms; the burst needs
17 ticks longer than vanilla's 120 (its waves arrive late by up to 2 ticks), but no tick takes a quarter of a second.  **It costs CPU**: 5.5 s over the 300 ticks against 2.5 s, because every tick pays the engine's set-up and write-back again
(10 to 20 ms of a 45 ms slice) for the part of the work that did not fit; set the budget to 0 for the lowest total and the longest tick.  The budget changes WHEN ticks run, never what a tick does; the one bug it had (a block pass that used up the whole budget starved the fluid ticks for 500 ticks) was found by a random test and fixed: every tick now runs at
least a slice of each kind.

The cap: `dbcraft.dynamics-max-ticks` stays vanilla's 65,536 per kind per tick with vanilla's semantics (the ticks over the limit stay queued in order); the budget is the lower, time-based limit.

### With the scoreboard's conditions (flat world, simulation and view distance 10, players spread over 960 x 960 blocks, the world pregenerated)

The final scoreboard campaign (docs/SCOREBOARD.md, a quiet machine, the tree before this change) measured dynamics ON against OFF: 50 idle players 15.4 against 5.7 ms per tick (every 4th tick
about 100 ms), a 1,000-block fill with a viewer 80 against 4.7 ms of tick cost (vanilla 19), a 100,000-block fill 297 against 6.5 ms (vanilla 352), one `set_block` statement 3.9 against 2.7 ms
(vanilla).  Reproduced here with the same settings in SQL (`mc.tick()` / `mc.server_tick()` called one transaction at a time, 50 and 200 `mc.player` rows spread over 960 x 960 blocks, 7,225
flat chunks, a fake viewer connection at the spawn for the edits; no gateway, no vanilla, so the absolute values are not the scoreboard's: the baseline tick here is 13 to 19 ms because the
synthetic players have pending visibility work).  **The machine was shared with other agents (load average 3 to 8), so every figure carries noise of about +-1 ms; ON and OFF were alternated
in blocks of 100 ticks (ABBA) or per repetition, never run one after the other.**

| | before (the tree the campaign measured) | now | target |
|---|---|---|---|
| 50 idle players, mean tick ON minus OFF | +46 ms (62.6 against 16.7, three ABBA blocks), every 4th tick 177 to 239 ms, worst tick 414 ms | **+0.5 and 0.0 ms** (two ABBA runs of 1,600 ticks; worst tick 41 against 33 ms) | at most +1 ms |
| 200 idle players, mean tick ON minus OFF | (not run; the rebuild cost grows with the area) | **+1.2, +1.4 and -0.7 ms** (three runs; in the first two no list was built, the harness had put the game clock below the queue's stamps; in the last 390 chunks were listed) | at most +1 ms |
| the engine's own cost per tick (`mc.dyn_step`, nothing due, 200 players) | | 0.05 ms (every 4th tick 0.3 ms with a list probe, 0.11 on the others at 50 players) | |
| fill 1,000 blocks with a viewer, tick cost (median / mean of 22, ON; OFF) | 80 ms (campaign) | **0.0 / 5.2 ms; OFF 2.1 / 21.7 ms** (OFF is as noisy as ON: the viewer's own encode work) | at or below vanilla's 19 ms |
| fill 100,000 blocks with a viewer, tick cost (median / mean; OFF) | 297 ms (campaign) | **3.8 / 16.7 ms; OFF 22.1 / 38.2 ms** | at or below vanilla's 352 ms |
| a `set_block` statement, ON minus OFF (24 batches of 1,000, ABBA) | 3.9 ms in the campaign (vanilla 2.7; OFF not given) | **+0.04 ms** (0.107 against 0.071 ms in a session; the statement is `mc.set_block` alone) | within +0.3 ms |
| worst single tick after an edit, ON | | 45 to 50 ms (a list build of 8 to 12 ms warm, 25 to 50 ms in a cold session, once per edit burst, 100 ticks after it) | no 100 ms spike |

What the causes were (found by reproducing, not guessed): the standing cost was the rebuild of the random-tick lists of every pregenerated chunk, 4 at a time every 4th tick at about 50 ms each, so
a world that had just been generated (or a fill that touched 36 chunks) paid it in the measured window; the fill and edit costs were the same rebuild, queued by the event trigger for every edit,
plus the trigger loading the engine's 1.5 MB of arrays for every statement; the `set_block` overhead was that trigger.  Now the trigger asks the palettes first and the rebuild is debounced,
budgeted and hashed (above).  A fill still runs the reactions of its cells in one statement when something reactive is in or next to it (at most 2,000 cells per event, as before); a fill of stone,
air or any other inert block does nothing.  The patching of lists cell by cell and the per-tick budget of the reaction pass of a fill, listed here as not done, were done in the round after (see "How it is built": patched lists, work queue).

### Standing cost of random ticks with 500 players (nothing scheduled)

500 players spread over 30 x 30 chunks, simulation distance 2, 2,810 flat grass chunks, about 1,150 chunks in range of some player; vanilla measured with one player and simulation distance 16
(1,089 chunks), the same chunk count.

| | CPU per tick |
|---|---|
| **vanilla**: `random_tick_speed 3` minus `0` (five alternations: 1.0, 1.1, 1.4, 1.1 ms; at 169 chunks 0.4 ms) | **about 1.15 ms** |
| dbcraft at the start of this round (4 random players' areas every 4th tick, 24 hits) | 5.0 ms (every 4th tick 15 to 30 ms) |
| dbcraft after the first rewrite (Poisson hits, per-section lists of all random-ticking cells) | 2.2 to 3 ms |
| dbcraft now (lists of active cells only) | **below 0.8 ms** (240 ticks: 200 ms in total, at the 10 ms resolution; every run is a probe of two tables) |

When something is active near a player (a farm, a grass edge with exposed dirt) a run with hits costs about 10 ms (the engine's fixed set-up per `mc.dyn_run`, a few hundred microseconds
per hit), every 4th tick: 2.5 ms per tick, vanilla's order for that many chunks plus the work of the hits themselves.  Rebuilding the lists is 3 to 12 ms per chunk with grass or crops, 4 chunks
per run at most, newest change first; a fresh world of 2,800 chunks takes 2,800 / 4 runs of every 4th tick (about 2.5 minutes) to be listed.

* Nothing scheduled, nobody online: 0.04 to 0.07 ms per `mc.dyn_step` (one statement); `dbcraft.dynamics = off`: the same statement returns at once.
* Reproduce: `tests/sql/880_dynamics.sql` (idle cost, relative to a trivial read so that it holds on a loaded machine); the layer burst is `tests/e2e/dyn_probe.py` scenario `water_layer`
  for the packets and the CPU harness described above for the cost (psql `\set c0 \`awk '{print ($14+$15)*10}' /proc/:pid/stat\``).
