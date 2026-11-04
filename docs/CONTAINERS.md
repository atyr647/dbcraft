# Containers, crafting and recipes (SQL)

The container-click protocol, the menus of the player inventory with its 2x2 grid, the crafting table, chests (single and double), barrels, ender chests, furnaces, blast
furnaces and smokers, recipe matching and smelting, as set-based SQL driven by rows: `sql/860`-`sql/866`, loader `tools/load_recipes.py`, tests `tests/sql/860_containers.sql`
and `tests/e2e/container_probe.py` / `compare_container.py` / `furnace_probe.py` / `check_recipes_vs_capture.py`.  Everything below is either read from the 26.3 bytecode
(`javap -c -p` on the classes of the pinned jar, the way `tools/pkt_layout.py` does; nothing is run) or something the **real vanilla 26.3 server** was seen to do, and what
is not verified is listed at the end.

## What was built

| Piece | Where | Source of the rules |
|---|---|---|
| Item rules: stack size, equipment slot, fuel burn time, crafting remainder | `ref.item_def`, loaded by `tools/load_recipes.py` | the data generator's default components of every item (`--reports`, kept in `$DBCRAFT_REPORTS/item_components`), the `cooking_fuel` providers in `data/minecraft/context_int_provider/cooking`, `Item.Properties.craftRemainder` in `Items.<clinit>` |
| Recipes: 827 shaped, 375 shapeless (358 loaded), 16 transmute, 73 smelting, 25 blasting, 9 smoking, 9 campfire, 351 stonecutting | `ref.recipe`, `ref.recipe_slot`, `ref.ingredient` (tags expanded to item lists) | `data/minecraft/recipe/**.json` of the jar, verbatim |
| Recipe matching: trimmed bounding box, mirrored shaped patterns, shapeless assignment (Hall's condition over the grid's items), transmute keeping the input's components | `mc.craft_match`, `mc.craft_result` (`861`) | `ShapedRecipePattern.matches`, `ShapelessRecipe.matches`, `CraftingInput.ofPositioned` |
| The click engine: `PICKUP` (left/right), `QUICK_MOVE` (shift), `SWAP` (hotbar keys and F), `CLONE` (creative), `THROW`, `QUICK_CRAFT` (drag, three types), `PICKUP_ALL` (double click), the carried item, state ids, resync | `mc.mi_click` and helpers (`862`) | `AbstractContainerMenu.clicked/doClick/moveItemStackTo`, `Slot.safeInsert/tryRemove/safeTake`, `InventoryMenu/CraftingMenu/ChestMenu/AbstractFurnaceMenu.quickMoveStack`, `ResultSlot.onTake`, `Inventory.add/placeItemBackInInventory` |
| What the server answers: `container_set_slot` for every slot that differs from the client's claim, `set_cursor_item`, a whole `container_set_content` for a stale state id, the result slot update on every grid change | `mc.mi_broadcast`, `mc.mi_fire` (`862`, `863`) | `ServerGamePacketListenerImpl.handleContainerClick`, `AbstractContainerMenu.broadcastChanges/sendAllDataToRemote`, `CraftingMenu.slotChangedCraftingGrid`, the `ServerPlayer` synchronizer |
| Menus as rows | `mc.menu_kind`, `mc.menu_slot_def` (`860`): which store and slot each menu slot is, who may place what | the menu constructors |
| Opening (`use_item_on`), still-valid checks, closing (client, server, block broken, player gone), the lid and the barrel state | `mc.menu_open`, `mc.menu_still_valid`, `mc.menu_do_close`, `mc.container_step` (`863`, `864`) | `ServerPlayerGameMode.useItemOn`, `ServerPlayer.openMenu/closeContainer/doCloseContainer`, `ContainerOpenersCounter` |
| Block contents: chests, barrels, furnaces as rows keyed by position, the ender chest per player; a broken block drops its contents | `mc.container_slot`, `mc.ender_slot`, trigger on `mc.block_event` (`865`) | `Containers.dropContents`, `ChestBlock` (double chest halves) |
| Furnaces: lit time, cooking progress, fuel, remainders, the block's `lit` property, the four `container_set_data` values | `mc.furnace`, `mc.furnace_step` (`866`) | `AbstractFurnaceBlockEntity.serverTick/consumeFuel/canBurn/burn/setItem` |
| Giving items the vanilla way (`/give` uses it) | `mc.inv_give` (`863`) | `Inventory.add`, `GiveCommand` |

## The model

* A **menu** is a kind (`inventory`, `crafting`, `generic_9x1`..`generic_9x6`, `furnace`, `blast_furnace`, `smoker`) plus, for block menus, a position.  `mc.menu_slot_def` maps
  every menu slot to a store (`inv` the player's inventory-menu slot, `grid` the crafting table's 3x3, `blk` the block's container, `res` the result) and a rule.
* A click is processed on a **value**, `mc.mst`: the open menu's slots loaded from the tables (`mc.mi_load`), changed in memory by the ported vanilla functions, written back
  as a diff (`mc.mi_store`).  An item stack is `(item, count, components)` where `components` is the raw hex of the `DataComponentPatch` exactly as the client sent it; stacks stack
  when item and raw patch are equal and the count is below the item's maximum.
* The server never trusts the client's stacks: the click is applied to the **server's** state, and the client's `changedSlots` / carried item (hashes) only say what the client
  already believes, so that the server does not repeat it.  The hashes are compared by item, count and the NUMBER of components (see "Not verified").
* The client's copy of every slot is not stored: it is what the server last sent, which after every click is the server's own state, so "remote == state before the click"
  except for the slots a client claims and the ones that change behind its back (a furnace, another player at the same chest): those are `mc.menu_state.blk_sent` and
  `inv_sent`.
* The state id is per menu: the inventory menu's is `mc.player.inv_state`, an open menu's `mc.menu_state.state_id`; it is incremented exactly where `incrementStateId()` is
  called in vanilla (every `container_set_slot`, every `container_set_content`, and the result slot update that the crafting grid sends on every change).

## Verified against the real vanilla server

`tests/e2e/container_probe.py` drives one scripted client against vanilla 26.3 (survival, a block placed and filled over RCON) and against dbcraft over TCP (the same preparation
through SQL) and records every container packet.  After EVERY click it sends a harmless click with a stale state id: the server answers with the whole menu, so the full state is
compared after every step, not just the packets that happen to be sent.  The first run uses EMPTY claims (the server must report every slot and the cursor that the click
changed); a second kind of run (`--claims`) claims what the client would predict, which must silence the server.  `compare_container.py` requires the packets of every step and the
full state after it to be equal.

### Results

`tests/e2e/container.sh` against the pinned 26.3 server (the numbers are from the last full pass; the recordings contain Mojang data and are not committed):

| What | Runs | Result |
|---|---|---|
| inventory with the 2x2 grid (`inv` seeds 1, 2; also 3-7 in earlier passes), crafting-heavy (`craft` 1, 2; also 3), crafting table (`table` 1, 2; also 3, 4), chest (`chest` 1, 2; also 3), double chest (`double` 1-4: all four facings), barrel (`barrel` 1), ender chest (`ender` 1) | 40 steps each (30 for barrel and ender), 540 steps per mode in the default set; empty claims AND claimed changes | every step's packets and the full menu state after it are equal: 27 of the 28 comparisons of the last pass at once; the 28th (`table` 1, empty claims) differed only by a stray `block_update` that vanilla sent for a far block, which the comparator now ignores (see below); `table` 1 was run again from scratch and passed in both modes |
| sneaking with an item in the hand next to a chest (`container_plan_sneak.py`) | 11 steps | equal: no menu opens, the clicked block and the block beside the face are sent again; standing up opens it |
| furnace, blast furnace, smoker (`furnace_probe.py`): opened empty, input and fuel written, 14 seconds | 3 kinds, 400-562 packets each | the sequence of `container_set_data` (lit time, progress, total) and slot updates is equal packet by packet |
| recipe rows against vanilla's `update_recipes` (`check_recipes_vs_capture.py`) | furnace 163 inputs, blast furnace 62, smoker 9, campfire 9, stonecutter 351 entries | equal |

What the comparator ignores, on purpose: the number of `block_event` lid re-signals in a window (vanilla and dbcraft both re-signal every 5 ticks, how many fall in a window depends on timing; only the opening and, in a close step, the closing event are compared); the intermediate result-slot packets of a drag across crafting-grid cells (hash order of slots, see below); the order of a barrel's closing `block_update` against the inventory broadcast; and any `block_update` that is not next to the container (vanilla sends such packets for single blocks of the flat world's top layer now and then, always at y = -61 with state 9 or 10; the cause was not found).  The harness waits for the server on a loaded machine and retries its inventory reset until the server confirms it, so a slow run is not a failed one.

SQL: `tests/sql/860_containers.sql` has 104 checks (click engine, every menu, recipes, crafting remainders, furnaces including a check that the set-based fast path equals the per-furnace transcription over 1100 ticks, sneaking, `/give`).  The whole suite `tests/sql/prun.sh` passed after the last change (59 files, 1981 checks).  `tools/check_overrides.py` (58 overrides, all listed), `tools/check_inlining.sh` and `tools/check_fresh_migration.sh` pass.

Cost (500 bench players on a shared, heavily loaded 16 GB machine, `mc.container_step` called as its own statement like the server does): **0.13-0.17 ms per tick when nothing is open and no furnace exists** (0.3% of the 50 ms budget; `furnace_step` 0.03 ms and `menu_sync` 0.02 ms of it); **6.2 ms per tick with 200 lit furnaces cooking** (a furnace that only counts is one row of one set-based `UPDATE`; before that fast path it was 228 ms, 1.1 ms per furnace).  A whole-tick A/B with `tests/bench/game/run.sh 500 100 1.0` was attempted but is not meaningful here: the load average was 12-22 and the tick average moved between 217 and 713 ms from run to run, far more than the cost above, so the per-call figures are the reliable ones.  The cost of one click was not measured separately.

## Not modelled / not verified (read this)

* **Component hashes.**  The client's `changedSlots` and carried item arrive as `HashedStack`s (item, count, a CRC32C hash of every component value).  dbcraft compares item,
  count and the NUMBER of added and removed components with its own stack; it does not compute the hashes (they are hashes of the codec encoding of each component, per
  component type).  Consequence: a client that claims a different component value than the server holds is not corrected.  The server never takes a stack from the client in a
  click (only creative slot packets carry real stacks), so this affects what the client is told, not what the server stores.
* **Components are raw bytes.**  A stack with components is stored as the client sent it (`components = {"raw_hex": ...}`), compared byte for byte, and written back unchanged;
  nothing is decoded: no `max_stack_size` override, no damage, no enchantments, no bundle contents, no container contents of a shulker box.  Stack sizes are the item's default.
* **Menus that do not exist yet:** hopper, dispenser, dropper, shulker box, anvil, grindstone, enchanting table, brewing stand, beacon, cartography table, loom, smithing table,
  stonecutter, lectern, villager trading, the crafter, horse and nautilus inventories.  Bundles (`overrideStackedOnOther`) are not handled in a click.
* **Recipes not loaded** (the grid gives no result): the special recipes (banner duplication, book cloning, firework rocket / star / fade, map extending and cloning, decorated pot,
  shield decoration, armor and item dyeing, repair), 17 shapeless recipes whose result carries components, smithing, brewing.  Loaded: 827 shaped, 358 shapeless, 32 transmute, 73
  smelting, 25 blasting, 9 smoking, 9 campfire, 351 stonecutting (the last four kinds only as data: campfires and the stonecutter menu do not exist).
* **`update_recipes` and `recipe_book_add`** are replayed from the capture, not generated: vanilla writes the property sets in `Set.copyOf` order, different in every JVM run, so
  no byte-exact generation exists.  `tests/e2e/check_recipes_vs_capture.py` compares the CONTENT: the furnace / blast furnace / smoker / campfire input sets and all 351
  stonecutter entries of vanilla's packet equal the rows.  The recipe book itself (`place_recipe`, `recipe_book_seen`, the settings, unlocking recipes) is not implemented:
  the packets are ignored and nothing is unlocked.
* **Experience from smelting** is given to the player directly (`mc.xp_give`, the fraction as a chance) when a furnace result is taken; vanilla spawns orbs.  Item drops (a throw,
  a click outside the window, items that fit nowhere, a broken container's contents) become item entities only with `dbcraft.entity-mode = inline`; otherwise the items are gone.
* **Drag order.**  Vanilla adds the slots of a drag in the order of a `HashSet<Slot>` (identity hash codes: different in every run).  dbcraft uses ascending slot order.  The
  final state is the same; the intermediate `container_set_slot(0, ...)` packets a drag over crafting grid cells sends can differ in content (the comparison ignores them).
* **Inventory changes by other code** (pickup in `sql/520`, death drops in `sql/832`, eating in `sql/834`, block placement in `sql/410`) still send their own `container_set_slot`
  for container 0 and bump `mc.player.inv_state`; with a menu open that is not what vanilla does (it broadcasts through the open menu).  `/give` uses `mc.inv_give` now.
* **Death** with a menu open, the grid or the cursor: not compared (the respawn resets the menu state; `sql/832` drops the grid cells with the inventory, vanilla does not).
* **Chest rules:** a chest with a solid block above it still opens (vanilla refuses), a cat sitting on it is not considered; custom container names are ignored; doubles only form
  when something sets the `type` states (player placement uses default states: `docs/GAME.md`); the chest lid and the barrel `open` state follow the openers, sounds are not sent.
* **Furnaces only tick with a row** in `mc.furnace` (written when a menu or SQL touches the slots; a furnace with nothing left to do loses it).  A furnace that was lit and cooking
  when a world was loaded from vanilla data has no row: block entity data is not imported.  A furnace in `steady` state (it only counts down and cooks) is advanced by one
  set-based `UPDATE`; the tests compare that path with the full transcription.  The comparison against vanilla covers one scenario per kind (3 raw iron or beef, 2 coal, 14 seconds):
  fuel running out, a full result slot, lava buckets, wet sponges and several recipes in a row are tested in SQL against the bytecode only.
* **Furnace timing.**  A furnace ticks in `mc.container_step`, i.e. in the packet phase of the tick, vanilla's in the block entity phase; open menus hear of the change one tick
  later like vanilla's.  Hoppers and the campfire do not exist.  `mc.server_tick_batched` (`sql/389`) does not run `mc.container_step` at all, like it does not run the survival steps.
* **Dimensions.**  Menus assume the overworld in `mc.menu_try_open` (as `mc.apply_block_actions` does); the rows carry the dimension.
* **CLONE** (middle click in creative) and **THROW in creative** were not compared (the harness runs survival: vanilla ignores clone there); they are ports of the same bytecode.

