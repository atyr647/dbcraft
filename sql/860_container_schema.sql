-- Containers, crafting and recipes, part 1: schema.  docs/CONTAINERS.md has the whole picture.
--
-- What lives where
--   ref.item_def, ref.ingredient, ref.recipe, ref.recipe_slot   what the jar says (tools/load_recipes.py): stack sizes, equipment slots, fuel burn times,
--                                                                crafting remainders; shaped / shapeless / transmute / cooking / stonecutting recipes
--   mc.inventory_slot (sql/330)      the player's own slots, in the numbering of vanilla's InventoryMenu: 0 result (never stored), 1-4 crafting grid, 5-8 armor
--                                    (head .. feet), 9-35 main inventory, 36-44 hotbar, 45 off hand
--   mc.menu_state                    one row per player who ever clicked a container: the menu that is open (none = the inventory menu), its container id and
--                                    state id, the carried item, a drag in progress, the result slot of the crafting grid
--   mc.menu_slot                     the 3x3 grid of an open crafting table
--   mc.container_slot                the slots of chests, barrels, furnaces (a row per NON-EMPTY slot, keyed by block position)
--   mc.ender_slot                    a player's ender chest
--   mc.furnace                       the burn state of a furnace block (lit time, cooking progress)
--   mc.menu_kind, mc.menu_slot_def   the menus as ROWS: which store and slot each menu slot is, who may put what where
-- Item stacks are (item, count, components) where components is the raw hex of the DataComponentPatch as the client sent it (mc.inventory_slot.components =
-- {"raw_hex": ...}); the bytes are never decoded, only compared (two stacks stack when item and raw patch are equal).

------------------------------------------------------------------------------------------------ reference data (tools/load_recipes.py)
create table if not exists ref.item_def (
    item        text primary key,
    max_stack   int  not null,
    max_damage  int,
    equip_slot  text,                 -- head | chest | legs | feet | offhand: the slot a PLAYER can wear it in (minecraft:equippable), null otherwise
    remainder   text,                 -- what stays in the crafting grid (Item.Properties.craftRemainder)
    burn_ticks  int,                  -- fuel: burn time in an ordinary furnace (minecraft:cooking_fuel, halved in a blast furnace or smoker)
    use_remainder text
);
create table if not exists ref.ingredient (id int primary key, items text[] not null);
create table if not exists ref.recipe (
    id text primary key, type text not null, category text, grp text,
    result_item text not null, result_count int not null,
    w int, h int,                      -- shaped: pattern size
    n_ingredients int not null,        -- non-empty cells (shaped), ingredient count (shapeless, transmute: 1 + material count)
    ingredient int references ref.ingredient (id),      -- cooking and stonecutting: the single ingredient
    cookingtime int, experience real,
    flag boolean                       -- transmute: add_material_count_to_result
);
create index if not exists recipe_lookup on ref.recipe (type, w, h, n_ingredients);
create index if not exists recipe_ing on ref.recipe (ingredient) where ingredient is not null;
create table if not exists ref.recipe_slot (
    recipe text not null references ref.recipe (id) on delete cascade,
    pos int not null,                  -- shaped: row * w + column of a NON-EMPTY cell; shapeless: the ingredient's number; transmute: 0 the input, 1.. the materials
    ingredient int not null references ref.ingredient (id),
    primary key (recipe, pos)
);

------------------------------------------------------------------------------------------------ the stack type and the menu state
do $$ begin
    if not exists (select 1 from pg_type where typname = 'stk' and typnamespace = 'mc'::regnamespace) then
        create type mc.stk as (item text, n int, comp text);       -- an ItemStack: item name, count, raw component patch (hex) or null; empty = item null
    end if;
end $$;

-- The working copy of one player's open menu while a click is processed (sql/862).  The slot maps (s_*) are the rows of mc.menu_slot_def for the kind;
-- inv holds the 46 slots of the player's inventory menu (index = slot + 1), blk the slots of the block container, grid the crafting table's 3x3.
-- rem0 is the client's copy of the result slot after the last grid change (ServerPlayer forces it when it sends the result); null = it matches the server.
-- r / ok / aux are the "return registers" of the helper functions (a helper returns the whole state with its result in them).
do $$ begin
    if not exists (select 1 from pg_type where typname = 'mst' and typnamespace = 'mc'::regnamespace) then
        create type mc.mst as (
            kind text, cid int, state_id int, gm int, held int, grid_w int,
            s_store text[], s_cs int[], s_rule text[], s_role text[], s_max int[],
            inv mc.stk[], blk mc.stk[], grid mc.stk[],
            carried mc.stk, result mc.stk, rem0 mc.stk,
            pkts bytea, drops mc.stk[],
            qc_type int, qc_status int, qc_slots int[],
            r mc.stk, ok boolean, aux int);
    end if;
end $$;

-- What a ServerboundContainerClickPacket claims about a slot: the HashedStack of the client's prediction (item, count, and the NUMBER of added / removed components:
-- the component hashes are not computed, see docs/CONTAINERS.md).  slot -1 is the carried item; item null = the client claims an empty slot.
do $$ begin
    if not exists (select 1 from pg_type where typname = 'claim' and typnamespace = 'mc'::regnamespace) then
        create type mc.claim as (slot int, item text, n int, added int, removed int);
    end if;
end $$;

create table if not exists mc.menu_state (
    player      uuid primary key references mc.player (uuid) on delete cascade,
    open        boolean not null default false,        -- a menu other than the inventory menu is open
    kind        text,                                  -- its kind (mc.menu_kind) while open
    container_id int not null default 0,               -- 0 = the inventory menu, otherwise ServerPlayer.containerCounter of the open menu
    counter     int not null default 0,                -- ServerPlayer.containerCounter: the next menu gets counter % 100 + 1
    state_id    int not null default 0,                -- the open menu's state id (the inventory menu's is mc.player.inv_state)
    dimension   text, x int, y int, z int,             -- the block the open menu belongs to (a double chest: x2, y2, z2 is the other half); dimension null: the player's ender chest
    x2 int, y2 int, z2 int,
    carried_item text, carried_n int not null default 0, carried_comp text,
    qc_type     int not null default 0, qc_status int not null default 0, qc_slots int[] not null default '{}',
    result_item text, result_n int not null default 0, result_comp text,    -- the result slot of the inventory menu's grid (or of the open crafting table)
    data        int[],                                 -- furnace menus: the client's copy of the four ContainerData values (lit time, lit duration, progress, total)
    blk_sent    mc.stk[],                              -- the client's copy of the block container's slots (what changes behind its back is sent next tick)
    opened_at   bigint,                                -- game tick the menu was opened (the chest lid is re-signalled every 5 ticks while it is open)
    stale       boolean not null default false,        -- the block of the open menu was replaced or broken (set by the trigger of sql/865): it closes at the next tick
    inv_sent    mc.stk[]                               -- what the INVENTORY menu believes the client has, for the slots the open menu does not show (grid, armor, off hand): the state when it was opened
) with (fillfactor = 70);
create index if not exists menu_state_open_idx on mc.menu_state (player) where open;

create table if not exists mc.menu_slot (
    player uuid not null references mc.player (uuid) on delete cascade,
    slot smallint not null, item text not null, count smallint not null check (count between 1 and 99), components jsonb,
    primary key (player, slot));
create table if not exists mc.container_slot (
    dimension text not null, x int not null, y int not null, z int not null,
    slot smallint not null, item text not null, count smallint not null check (count between 1 and 99), components jsonb,
    primary key (dimension, x, y, z, slot));
create table if not exists mc.ender_slot (
    player uuid not null references mc.player (uuid) on delete cascade,
    slot smallint not null, item text not null, count smallint not null check (count between 1 and 99), components jsonb,
    primary key (player, slot));
create table if not exists mc.furnace (
    dimension text not null, x int not null, y int not null, z int not null,
    kind text not null default 'furnace',              -- furnace | blast_furnace | smoker (the last two burn fuel in half the time and cook at twice the speed)
    speed real not null default 1,                     -- AbstractFurnaceBlockEntity.speedMultiplier of the fuel being burnt
    lit_time int not null default 0,                   -- AbstractFurnaceBlockEntity.litTimeRemaining
    lit_duration int not null default 0,               -- litTotalTime
    cook_progress int not null default 0, cook_total int not null default 0,
    recipes_used jsonb not null default '{}',          -- recipe id -> times used (awards experience when the result is taken)
    steady boolean not null default false,             -- the next tick only counts: lit time down, progress up (nothing is consumed or produced, the block does not change): one set-based UPDATE
    primary key (dimension, x, y, z));

-- (shipped with the join: the player's sneaking flag, from player_input) ------------------------------------------------------------------
alter table mc.player add column if not exists sneaking boolean not null default false;

------------------------------------------------------------------------------------------------ the menus as rows
create table if not exists mc.menu_kind (
    kind text primary key,
    menu_type text not null,              -- the registry name sent in open_screen (minecraft:menu)
    n_slots int not null,
    grid_w int                            -- crafting grids: the grid's width
);
-- store: 'res' the crafting result container, 'inv' the player's inventory-menu slot cs, 'grid' the crafting table's grid cell cs, 'blk' the block container's slot cs
-- rule (who may place): any | none | fuel | head | chest | legs | feet.   role: null | grid (a change recomputes the result) | craft_result | furnace_result
create table if not exists mc.menu_slot_def (
    kind text not null references mc.menu_kind (kind) on delete cascade,
    idx int not null, store text not null, cs int not null, rule text not null default 'any', role text, max_stack int not null default 99,
    primary key (kind, idx));

do $$
declare k text; r int; n int;
begin
    if exists (select 1 from mc.menu_kind) then return; end if;
    insert into mc.menu_kind values ('inventory', 'minecraft:crafting', 46, 2), ('crafting', 'minecraft:crafting', 46, 3),
        ('furnace', 'minecraft:furnace', 39, null), ('blast_furnace', 'minecraft:blast_furnace', 39, null), ('smoker', 'minecraft:smoker', 39, null);
    for r in 1..6 loop insert into mc.menu_kind values ('generic_9x' || r, 'minecraft:generic_9x' || r, 9 * r + 36, null); end loop;
    -- the player's own menu (InventoryMenu): result, 2x2 grid, armor head..feet, main, hotbar, off hand
    insert into mc.menu_slot_def (kind, idx, store, cs, rule, role, max_stack)
    select 'inventory', i, case when i = 0 then 'res' else 'inv' end, i,
           case i when 5 then 'head' when 6 then 'chest' when 7 then 'legs' when 8 then 'feet' when 0 then 'none' else 'any' end,
           case when i = 0 then 'craft_result' when i between 1 and 4 then 'grid' end,
           case when i between 5 and 8 then 1 else 99 end
      from generate_series(0, 45) i;
    -- the crafting table (CraftingMenu): result, 3x3 grid, main, hotbar
    insert into mc.menu_slot_def (kind, idx, store, cs, rule, role)
    select 'crafting', i, case when i = 0 then 'res' when i <= 9 then 'grid' else 'inv' end,
           case when i = 0 then 0 when i <= 9 then i - 1 when i <= 36 then i - 1 else i - 1 end,
           case when i = 0 then 'none' else 'any' end, case when i = 0 then 'craft_result' when i <= 9 then 'grid' end
      from generate_series(0, 45) i;
    -- chest-like menus (ChestMenu): the rows, then the player's main inventory, then the hotbar
    for r in 1..6 loop
        insert into mc.menu_slot_def (kind, idx, store, cs)
        select 'generic_9x' || r, i, case when i < 9 * r then 'blk' else 'inv' end, case when i < 9 * r then i else i - 9 * r + 9 end from generate_series(0, 9 * r + 35) i;
    end loop;
    -- furnaces (AbstractFurnaceMenu): input, fuel, result, main, hotbar
    foreach k in array array['furnace', 'blast_furnace', 'smoker'] loop
        insert into mc.menu_slot_def (kind, idx, store, cs, rule, role)
        select k, i, case when i < 3 then 'blk' else 'inv' end, case when i < 3 then i else i - 3 + 9 end,
               case i when 1 then 'fuel' when 2 then 'none' else 'any' end, case when i = 2 then 'furnace_result' end from generate_series(0, 38) i;
    end loop;
end $$;
-- the crafting table's slot numbers, spelled out: idx 10-36 are the main inventory (inventory slots 9-35), 37-45 the hotbar (36-44)
update mc.menu_slot_def set cs = idx - 1 where kind = 'crafting' and idx >= 10;

-- A player who leaves must not take the open menu with them: the next join starts with the inventory menu.
-- (mc.menu_close_on_leave, sql/863, is attached to mc.player there.)
