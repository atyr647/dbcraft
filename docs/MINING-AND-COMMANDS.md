# Mining, drops, block-position commands, weather, spawn points, text components

What this work added to the survival game, how each piece was checked against the **real vanilla 26.3 server**, and what is still not verified.  Everything is SQL
(`sql/840` to `sql/896`); the Java dumpers read the pinned server jar; nothing of Mojang's is committed (the data is derived on your machine, like the sound data).

## How it was checked

* The recorder is a scripted client (`tests/e2e/mcclient.py`), run against a vanilla server started by `tests/e2e/vanilla_start.sh` (fresh flat world, `-Xms1G -Xmx2G`,
  operators `Surv` and `Obs`) and against a dbcraft dev gateway; the packets each client received are reduced and compared in order.
* The Java rules were read from the 26.3 bytecode (`javap -c -p`) before anything was written: `ServerPlayerGameMode`, `ServerGamePacketListenerImpl.handlePlayerAction`,
  `Player.getDestroySpeed`, `ItemStack` / `Item` / `Tool`, `ServerLevel.advanceWeatherCycle`, `WallBlock`, the command classes; the numbers (hardness, tool rules, loot tables)
  by `tools/java/MiningDump.java` and the data generator reports.
* SQL-level tests pin the recorded values (`tests/sql/891_mining.sql`: the 40 recorded dig times, damage patches, loot).

## 1. The mining protocol (`sql/840`, `891`; hooks in `sql/430`, `432`)

Before: a survival player's `STOP_DESTROY_BLOCK` broke the block whatever the time since the start; no hardness, no tools, no crack animation, no durability.

| Vanilla | dbcraft |
|---|---|
| `START_DESTROY_BLOCK` (action 0): creative breaks at once; adventure / spectator are sent the real state; survival computes the destroy progress and either breaks at once (progress >= 1, "insta mine") or starts the dig and tells every OTHER player within 32 blocks `block_destruction` (stage `int(progress * 10)`) | `mc.mining_action` |
| every tick of the dig: the stage when it changed (to the others), `level_event` 2019 (2020 every 4th tick) to everybody within 64 blocks, the digger too | `mc.mining_tick`, called by `mc.apply_block_actions` after the tick's packets |
| `STOP_DESTROY_BLOCK` (3): accepted when `progress * (ticks + 1) >= 0.7`; the crack is cleared (stage -1) and the block breaks.  Otherwise the dig is "delayed": the server keeps counting by itself (see the quirk below) | same |
| `ABORT_DESTROY_BLOCK` (2), `CHANGE_DESTROY_DIRECTION` (1): end the dig / change the direction of the 2019 events; every packet is acknowledged | same |
| a block out of reach (4.5, creative 5.0, plus 1.0 of slack, from the eye: 1.62 or 1.27 sneaking) is ignored (an abort still ends a dig); above y 319 the client is sent the state | `mc.in_dig_reach` |

**Destroy progress** = `speed / hardness / (30 with the correct tool or none needed, else 100)`, in float32.  `speed`: the held item's `minecraft:tool` rule for the block (the
first rule with a speed that names it, else the tool's default; no tool component: 1), `* 0.2` with the eyes in water, `/ 5` off the ground.  Hardness and "requires the
correct tool" per block come from the game itself (`MiningDump.java`: `BlockState.getDestroySpeed`, `requiresCorrectToolForDrops`; no block state differs from its block's
default and no class overrides `getDestroyProgress`: checked, 0 exceptions).  Tool rules are the data generator's item components; their `#tags` are expanded from the data
pack tags (`ref.item_tool_block`, 7,686 rows, so a lookup is one primary-key probe).

**A vanilla quirk, reproduced**: a refused stop packet starts the "delayed destroy", whose progress is computed with `delayedTickStart + 1`, the player's game tick at the START, as the
tick count (the call passes the start tick, not the elapsed ticks).  A player who has been online for a while therefore breaks the block one tick after the refused packet (the
crack packet carries a stage far above 10, `& 255`); a player who just joined never does.  dbcraft keeps `gameTicks` per player (from the join tick) to behave the same; the
chunk broadcast of that break comes one tick later than the packets', as in vanilla (the players tick after the chunks): `mc.mining.pend`, `mc.mining_flush`.

**Breaking** (`mc.mining_destroy`, `ServerPlayerGameMode.destroyBlock`): refused (the client is sent the state) for a creative player holding a sword (`can_destroy_blocks_in_creative:
false`), a game master block without a creative operator (command blocks, structure blocks, jigsaw, test blocks), adventure / spectator.  The cell becomes air (water when
waterlogged).  Survival: the tool loses `damage_per_block` durability when the block's hardness is not 0 (`minecraft:damage` in the stack's component patch, `01 00 03 <n>`,
recorded; a tool at its max damage vanishes with `entity_event 47`); exhaustion +0.005 and the loot only when the tool is the correct one (or none is needed).  The slot update goes out
after the tick's block updates and before the acknowledgement (`mc.mining_out`, recorded order).

**Drops** (`sql/892`): vanilla drops are item *entities*, so they exist only with `dbcraft.entity-mode = inline` (the same rule as the items of a closed chest, `sql/863`); with the
entity simulation off a broken block drops nothing.  The block loot tables of the jar (1,201 files, `tools/gen_mining.sh` copies them) are interpreted in SQL: the entries
`item`, `alternatives`, `dynamic`; the conditions `survives_explosion`, `match_block` (with state properties), `match_tool` (items and tags), `location_check`, `table_bonus`,
`random_chance`, `entity_properties`, `any_of` / `all_of` / `inverted`, the predicates `tool/can_shear` and `tool/can_silk_touch`; the modifiers `set_count`, `apply_bonus`,
`limit_count`, `explosion_decay`.  The item entity appears at the block's centre +-0.25 with the velocity of `ItemEntity`'s constructor and a 10 tick pickup delay.  The game rule
`block_drops` stops player mining drops (recorded) but not `/setblock destroy` and `/fill destroy` (recorded: they drop anyway).

### Evidence

MINING_EVIDENCE

### Not modelled / not verified

* **Enchantments** (efficiency, unbreaking, silk touch, fortune, aqua affinity) and **potion effects** (haste, mining fatigue; no effects exist): item components other than the
  damage are kept but not read; silk touch is never true and fortune is 0 in the loot tables.  The destroy speed attributes are their defaults.
* A stack whose component patch has other components than `damage` is not given durability loss (its damage cannot be located without decoding every component type).
* Experience from ores, the contents of block entities (a broken chest's items are the container module's, `sql/865`), piglin anger, spawn protection, the world border.
* The tick in which a dig starts is taken from the server's tick counter; the real server's per-player counter starts at the player's creation, dbcraft's at `join_tick` (not
  reset at a respawn), which only matters for the delayed-destroy quirk right after joining.
* The break effect of a waterlogged block (2001 to the others) is not sent (the cell does not become air: the existing broadcast sends it only for air).
* Mining while the `player_loaded` gate is closed (vanilla drops those packets for up to 60 ticks), the on-ground flag after a teleport (taken from the last movement packet).

## 2. Block-position commands (`sql/811`, `813`, `893` to `896`)

New command argument parsers in `mc.cmd_arg` (`sql/811`): `block_pos` (absolute integers, `~` / `~n` relative to the executor's feet, `^` local), `block_state`, `block_predicate`
(`block[prop=value]`, `#tag[prop=value]`) and `component` (SNBT, below), all with the cursor and key of vanilla's errors (`argument.pos.mixed`, `argument.pos3d.incomplete`,
`parsing.int.expected`, `argument.block.id.invalid` with `minecraft:` for an empty id, `argument.block.property.*`, `argument.block.tag.disallowed`,
`arguments.block.tag.unknown` ...).

COMMAND_EVIDENCE

### Notes

* `/setblock`: modes replace / keep / destroy / strict; a cell that already has the state fails; destroying air with air "succeeds" and changes nothing.  Only chunks dbcraft has count
  as loaded (`argument.pos.unloaded`); outside y -64..319 or +-3e7 is `argument.pos.outofworld`.
* `/fill`: replace [filter] / keep / outline / hollow through `mc.fill_mode` (`sql/961`, which now also takes `#tag[prop=value]` filters); `destroy` goes block by block (break
  effect, loot, then the new block; the count is the positions whose state changed); more than `max_block_modifications` positions: `commands.fill.toobig` with the limit and the
  size.  `strict` is accepted and acts like the default (the neighbour updates of a fill are the dynamics engine's own).  `/clone` is not implemented.
* `/spawnpoint [targets [pos [rotation]]]` and `/setworldspawn [pos [rotation]]` (new in 26.3: the rotation): the feedback carries x y z (ints), yaw pitch (floats), the dimension
  and the player or the count; a changed world spawn is broadcast as `set_default_spawn_position`; `/spawnpoint` sends nothing to the client and a dead player respawns at its point
  (`mc.player_spawn`, `sql/836`).
* `/weather`: see the next section.  `/time`: `set` (the next occurrence of a marker; "already at" when sitting on it), `add`, `query gametime|time`, `query <timeline> [repetition]`
  (day, moon, villager_schedule: the jar's periods), `pause`, `resume`, `rate`, and every form with `of <clock>` for `minecraft:overworld` (the end clock is not modelled).  The
  `set_time` packet of a command carries the clock with partial tick 0 and rate 0, exactly as recorded.
* Text components (`/tellraw`, `/title`): the argument is SNBT, so every JSON component is one.  Decoded and re-encoded like the component codec (a literal without style or
  siblings is a bare string tag, a list is its first element with the others as `extra`, a compound's keys come out in **Java `HashMap` order**: bucket `(h ^ h>>>16) & 15`,
  insertion order inside a bucket; found by comparing the recordings, `mc.java_hash_order`).  Supported: text, translate (+ fallback, with), keybind, selector (resolved to the
  names), score and nbt (resolved to nothing: no scoreboards or data), color, bold italic underlined strikethrough obfuscated, shadow_color, insertion, font, click_event,
  hover_event, extra.  The codec's error texts are reproduced for the recorded cases (a number, a boolean, `{}`, `[]`, a compound without content, a bad colour, a non-numeric flag).
  `/title`: title, subtitle, actionbar, times, clear, reset; `/tellraw`.  Not done: `/dialog`, `/bossbar`, `/team`, text with `score` / `nbt` that resolve to something.

## 3. The weather clock (`sql/894`)

`ServerLevel.advanceWeatherCycle` and `MinecraftServer.setWeatherParameters` ported from the bytecode (`mc.weather_tick`, one line in `mc.tick_core`): the flags, the counters
(`clear_time`, `rain_time`, `thunder_time`) and the levels (`rain_level`, `thunder_level`, `float` steps of 0.01 per tick: the recorded values show `0.0599999..` style rounding),
`game_event` 7 / 8 for each changed level, 2 / 1 when the rain level crosses 0.2.  `/weather clear|rain|thunder [duration]` only sets the counters, as vanilla does (no
immediate packet); no duration is a random one (12,000..180,000 clear; 12,000..24,000 rain; 3,600..15,600 thunder).  The natural cycle runs too (random delays of 12,000 to
180,000 ticks).  A quirk of the real server, reproduced: when a `clear` period ends the weather turns to rain AND thunder (the pinned counters toggle the flags).  Not modelled: the
weather a player is told when it joins during rain.

WEATHER_EVIDENCE

## 4. Walls (`sql/890`)

`mc.wall_state`: `WallBlock.getStateForPlacement` / `updateShape`: each side connects (`WallBlock.connectsTo`: walls, sturdy sides, bars and panes, gates along the wall) as `low`,
or `tall` when the block above has a sturdy bottom face; the post (`up`) by `shouldRaisePost`.  The collision shapes of the blocks above are only known as "full" / "centre
support", so a block above that covers part of a strip counts as covering the post only.  Also new in the shape updates: `snowy` of grass, podzol and mycelium follows the block above
(found by the dig recording: breaking a snow block changed two cells).

WALL_EVIDENCE

## Files

`tools/java/MiningDump.java`, `tools/gen_mining.sh`, `tools/load_mining.py` (hardness, tool rules, loot tables); `sql/840_mining_ref.sql`, `891_mining.sql`, `892_loot.sql`,
`893_cmd_blocks.sql`, `894_weather.sql`, `895_cmd_spawn.sql`, `896_cmd_component.sql`; edits in place: `sql/811` (parsers), `813` (`/time`, `/weather`), `430` / `432` (the mining
hooks), `836` (respawn), `837` (the tick), `890` (walls, snowy), `961` (`#tag[props]` filters).  Probes and comparators: `tests/e2e/mine_probe.py` + `compare_mine.py`,
`cmd_blocks.py`, `weather_probe.py`; `tests/sql/891_mining.sql`.
