-- Containers, crafting and recipes (sql/860-866): the click engine, the menus of blocks, recipes, furnaces.
-- The click rules were compared with the REAL vanilla 26.3 server over randomized click sequences (tests/e2e/container_probe.py, compare_container.py: docs/CONTAINERS.md);
-- the expectations below are the same rules, small enough to read.  Needs the item rules and recipes (tools/load_recipes.py: the template of tests/sql/prun.sh has them);
-- without them the whole file is skipped with a notice.
select (select count(*) from ref.recipe) > 0 and (select count(*) from ref.item_def) > 0 and (select count(*) from net.static_packet) >= 6 as have_data \gset
\if :have_data
create or replace function t.cid() returns uuid language sql as $$ select '00000000-0000-0000-0000-00000000c0a1'::uuid $$;
create or replace function t.conn() returns int language sql as $$ select 7771 $$;
-- a clean world with one survival player standing at 0.5 -60 0.5
create or replace function t.fresh() returns void language plpgsql as $$
begin
  truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick, mc.pending_ack, mc.block_event, mc.block_actor;
  delete from mc.player; delete from mc.container_slot; delete from mc.furnace; delete from mc.menu_state;
  perform mc.configure_dev_server('test', 'survival');
  perform mc.reset_dev_world(2);
  insert into mc.player (uuid, name, gamemode, conn_id, entity_id, x, y, z, chunk_x, chunk_z, held_slot) values (t.cid(), 'Cont', 0, t.conn(), 7771, 0.5, -60, 0.5, 0, 0, 0);
  update mc.game_state set game_time = 1000;
end $$;
create or replace function t.give(p_slot int, p_item text, p_n int, p_comp text default null) returns void language sql as $$
  select mc.set_slot(t.cid(), p_slot, p_item, p_n, case when p_comp is null then null else jsonb_build_object('raw_hex', p_comp) end) $$;
create or replace function t.slot(p_slot int) returns text language sql as $$
  select coalesce((select replace(item, 'minecraft:', '') || ' x' || count from mc.inventory_slot where player = t.cid() and slot = p_slot), '-') $$;
create or replace function t.carried() returns text language sql as $$
  select coalesce((select replace(carried_item, 'minecraft:', '') || ' x' || carried_n from mc.menu_state where player = t.cid() and carried_n > 0), '-') $$;
create or replace function t.result() returns text language sql as $$
  select coalesce((select replace(result_item, 'minecraft:', '') || ' x' || result_n from mc.menu_state where player = t.cid() and result_n > 0), '-') $$;
create or replace function t.state() returns int language sql as $$
  select case when coalesce((select open from mc.menu_state where player = t.cid()), false) then (select state_id from mc.menu_state where player = t.cid())
              else (select inv_state from mc.player where uuid = t.cid()) end $$;
create or replace function t.cur_cid() returns int language sql as $$ select coalesce((select container_id from mc.menu_state where player = t.cid() and open), 0) $$;
-- a ServerboundContainerClickPacket with EMPTY claims (the server reports every change), against the current menu and state id; returns what the player was sent
create or replace function t.click(p_slot int, p_button int, p_input int, p_state int default null) returns bytea language plpgsql as $$
begin
  truncate mc.play_out;
  perform mc.menu_handle_click(t.cid(), proto.varint(t.cur_cid()) || proto.varint(coalesce(p_state, t.state())) || proto.i16(p_slot) || proto.i8(p_button) || proto.varint(p_input)
                                        || proto.varint(0) || '\x00'::bytea);
  return coalesce((select string_agg(data, '\x'::bytea order by seq) from mc.play_out where conn_id = t.conn()), '\x'::bytea);
end $$;
create or replace function t.out() returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = t.conn() $$;
create or replace function t.names(d bytea) returns text[] language plpgsql as $$
declare o int := 0; l record; i record; r text[] := '{}'; nm text;
begin
  while o < length(d) loop
    select * into l from proto.varint_read(d, o); select * into i from proto.varint_read(d, l.nxt);
    select replace(name, 'minecraft:', '') into nm from ref.packet where state = 'play' and direction = 'clientbound' and protocol_id = i.val;
    r := r || coalesce(nm, '#' || i.val); o := l.nxt + l.val;
  end loop;
  return r;
end $$;
create or replace function t.use_item_on(p_x int, p_y int, p_z int, p_seq int default 5) returns void language sql as $$
  insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('use_item_on'),
    proto.varint(0) || proto.position(p_x, p_y, p_z) || proto.varint(1) || proto.f32(0.5) || proto.f32(1) || proto.f32(0.5) || '\x0000'::bytea || proto.varint(p_seq)) $$;

------------------------------------------------------------------------------------------------ the item rules and the recipes come from the jar
select t.eq('stack sizes from the generator', (select array_agg(max_stack order by item) from ref.item_def where item in ('minecraft:bucket', 'minecraft:water_bucket', 'minecraft:stone', 'minecraft:iron_sword', 'minecraft:ender_pearl', 'minecraft:oak_sign')), array[16, 16, 1, 16, 64, 1]);
select t.eq('crafting remainders: the three buckets and two bottles', (select array_agg(item || '>' || remainder order by item) from ref.item_def where remainder is not null),
       array['minecraft:dragon_breath>minecraft:glass_bottle', 'minecraft:honey_bottle>minecraft:glass_bottle', 'minecraft:lava_bucket>minecraft:bucket', 'minecraft:milk_bucket>minecraft:bucket', 'minecraft:water_bucket>minecraft:bucket']);
select t.eq('fuel burn times: coal 1600, blaze rod 2400, lava bucket 20000, planks 300, stick 100', (select array_agg(burn_ticks order by item) from ref.item_def where item in ('minecraft:coal', 'minecraft:blaze_rod', 'minecraft:lava_bucket', 'minecraft:oak_planks', 'minecraft:stick')), array[2400, 1600, 20000, 300, 100]);
select t.eq('equipment slots the player can use', (select array_agg(equip_slot order by item) from ref.item_def where item in ('minecraft:iron_helmet', 'minecraft:iron_chestplate', 'minecraft:iron_leggings', 'minecraft:iron_boots', 'minecraft:shield', 'minecraft:elytra', 'minecraft:carved_pumpkin')), array['head', 'chest', 'feet', 'chest', 'head', 'legs', 'offhand']);
select t.eq('recipes of the supported kinds', (select count(*)::int from ref.recipe where type = 'crafting_shaped') || '/' || (select count(*)::int from ref.recipe where type = 'stonecutting') || '/' || (select count(*)::int from ref.recipe where type = 'smelting'), '827/351/73');

------------------------------------------------------------------------------------------------ matching (ShapedRecipePattern / ShapelessRecipe / CraftingInput)
select t.eq('2 planks in a column make sticks', mc.craft_match(2, 2, array['minecraft:oak_planks', null, 'minecraft:oak_planks', null]), 'minecraft:stick');
select t.eq('the same two in the right column (the grid is trimmed)', mc.craft_match(2, 2, array[null, 'minecraft:oak_planks', null, 'minecraft:oak_planks']), 'minecraft:stick');
select t.eq('two planks side by side are a pressure plate, not sticks', mc.craft_match(2, 2, array['minecraft:oak_planks', 'minecraft:oak_planks', null, null]), 'minecraft:oak_pressure_plate');
select t.eq('4 planks: a crafting table', mc.craft_match(2, 2, array['minecraft:oak_planks', 'minecraft:oak_planks', 'minecraft:oak_planks', 'minecraft:oak_planks']), 'minecraft:crafting_table');
select t.eq('a diagonal is no recipe (the cells between must be empty)', mc.craft_match(2, 2, array['minecraft:oak_planks', null, null, 'minecraft:oak_planks']), null);
select t.eq('a log makes planks (a tag ingredient, shapeless)', mc.craft_match(2, 2, array['minecraft:oak_log', null, null, null]), 'minecraft:oak_planks');
select t.eq('an axe, written one way', mc.craft_match(3, 3, array['minecraft:iron_ingot'::text, 'minecraft:iron_ingot', null, 'minecraft:iron_ingot', 'minecraft:stick', null, null, 'minecraft:stick', null]), 'minecraft:iron_axe');
select t.eq('an axe, mirrored', mc.craft_match(3, 3, array[null, 'minecraft:iron_ingot'::text, 'minecraft:iron_ingot', null, 'minecraft:iron_ingot', 'minecraft:stick', null, null, 'minecraft:stick']), 'minecraft:iron_axe');
select t.eq('shapeless: white and red dye make pink dye in any cells', mc.craft_match(3, 3, array[null, null, 'minecraft:red_dye', null, 'minecraft:white_dye', null, null, null, null]), 'minecraft:pink_dye_from_red_white_dye');
select t.eq('an empty grid matches nothing', mc.craft_match(3, 3, array[null, null, null, null, null, null, null, null, null]::text[]), null);
select t.eq('a pickaxe needs its exact shape', mc.craft_match(3, 3, array['minecraft:cobblestone', 'minecraft:cobblestone', 'minecraft:cobblestone', null, 'minecraft:stick', null, null, 'minecraft:stick', null]), 'minecraft:stone_pickaxe');
select t.eq('...and not with a stick missing', mc.craft_match(3, 3, array['minecraft:cobblestone', 'minecraft:cobblestone', 'minecraft:cobblestone', null, 'minecraft:stick', null, null, null, null]), null);

------------------------------------------------------------------------------------------------ pickup, place, split, merge, swap (AbstractContainerMenu.doClick PICKUP)
select t.fresh();
select t.give(36, 'minecraft:oak_planks', 8); select t.give(37, 'minecraft:stick', 3); select t.give(38, 'minecraft:bucket', 16); select t.give(39, 'minecraft:bucket', 3);
select t.eq('a click on a stack picks it up: a slot update and the cursor', t.names(t.click(36, 0, 0)), array['container_set_slot', 'set_cursor_item']);
select t.eq('the slot is empty, the planks are carried', t.slot(36) || ' / ' || t.carried(), '- / oak_planks x8');
select t.eq('the state id went 1 -> 2', t.state(), 2);
select t.click(40, 1, 0);
select t.eq('a right click on an empty slot puts one down', t.slot(40) || ' / ' || t.carried(), 'oak_planks x1 / oak_planks x7');
select t.click(37, 0, 0);
select t.eq('a click on a different stack swaps them', t.slot(37) || ' / ' || t.carried(), 'oak_planks x7 / stick x3');
select t.click(38, 0, 0);
select t.eq('...again', t.slot(38) || ' / ' || t.carried(), 'stick x3 / bucket x16');
select t.click(39, 0, 0);
select t.eq('buckets stack to 16: 16 carried onto 3 fills the stack and keeps 3 on the cursor', t.slot(39) || ' / ' || t.carried(), 'bucket x16 / bucket x3');
select t.click(36, 0, 0);
select t.eq('the rest goes into an empty slot', t.slot(36) || ' / ' || t.carried(), 'bucket x3 / -');
select t.click(39, 1, 0);
select t.eq('a right click on a stack takes half, rounded up', t.slot(39) || ' / ' || t.carried(), 'bucket x8 / bucket x8');
select t.click(36, 1, 0);
select t.eq('a right click with the same item on a stack adds one', t.slot(36) || ' / ' || t.carried(), 'bucket x4 / bucket x7');
select t.eq('a stale state id answers with the whole menu and increments the state id once', t.names(t.click(-1, 0, 0, 20)) || array[t.state()::text], array['container_set_content', '10']);
truncate mc.play_out;
select mc.menu_handle_click(t.cid(), proto.varint(9) || proto.varint(1) || proto.i16(5) || proto.i8(0) || proto.varint(0) || proto.varint(0) || '\x00'::bytea);
select t.eq('a click on another container id is ignored: nothing is sent', length(t.out()), 0);

------------------------------------------------------------------------------------------------ quick move (shift click)
select t.fresh();
select t.give(36, 'minecraft:iron_helmet', 1); select t.give(37, 'minecraft:shield', 1); select t.give(38, 'minecraft:cobblestone', 64); select t.give(9, 'minecraft:iron_boots', 1);
select t.click(36, 0, 1);
select t.eq('a helmet from the hotbar goes to the head slot', t.slot(5) || ' / ' || t.slot(36), 'iron_helmet x1 / -');
select t.click(37, 0, 1);
select t.eq('a shield goes to the off hand', t.slot(45) || ' / ' || t.slot(37), 'shield x1 / -');
select t.click(9, 0, 1);
select t.eq('boots from the main inventory go to the boots slot', t.slot(8) || ' / ' || t.slot(9), 'iron_boots x1 / -');
select t.click(38, 0, 1);
select t.eq('cobblestone from the hotbar goes to the main inventory (slot 9 first)', t.slot(9) || ' / ' || t.slot(38), 'cobblestone x64 / -');
select t.click(9, 0, 1);
select t.eq('and back into the hotbar (the first free hotbar slot)', t.slot(36) || ' / ' || t.slot(9), 'cobblestone x64 / -');
select t.click(5, 0, 1);
select t.eq('the helmet leaves the head slot for the main inventory', t.slot(9) || ' / ' || t.slot(5), 'iron_helmet x1 / -');

------------------------------------------------------------------------------------------------ swap with a hotbar key
select t.fresh();
select t.give(10, 'minecraft:oak_planks', 5); select t.give(36, 'minecraft:stick', 2); select t.give(37, 'minecraft:bucket', 4);
select t.click(10, 0, 2);
select t.eq('key 1 swaps slot 10 with hotbar slot 0', t.slot(10) || ' / ' || t.slot(36), 'stick x2 / oak_planks x5');
select t.click(11, 1, 2);
select t.eq('key 2 into an empty slot moves the hotbar stack', t.slot(11) || ' / ' || t.slot(37), 'bucket x4 / -');
select t.click(12, 40, 2);
select t.eq('F with two empty slots does nothing', t.slot(12) || ' / ' || t.slot(45), '- / -');
select t.click(10, 40, 2);
select t.eq('F swaps with the off hand', t.slot(45) || ' / ' || t.slot(10), 'stick x2 / -');

------------------------------------------------------------------------------------------------ drag (QUICK_CRAFT): header 0 start, 1 add a slot, 2 end; type (button >> 2): 0 spread evenly, 1 one each
select t.fresh();
select t.give(36, 'minecraft:cobblestone', 7);
select t.click(36, 0, 0);
select t.click(-999, 0, 5); select t.click(10, 1, 5); select t.click(11, 1, 5); select t.click(12, 1, 5); select t.click(-999, 2, 5);
select t.eq('a left drag spreads 7 over 3 slots: 2 each, 1 stays on the cursor', t.slot(10) || ' ' || t.slot(11) || ' ' || t.slot(12) || ' / ' || t.carried(), 'cobblestone x2 cobblestone x2 cobblestone x2 / cobblestone x1');
select t.click(-999, 4, 5); select t.click(13, 5, 5); select t.click(-999, 6, 5);
select t.eq('a right drag over one slot is an ordinary right click: one item', t.slot(13) || ' / ' || t.carried(), 'cobblestone x1 / -');

------------------------------------------------------------------------------------------------ double click collects (PICKUP_ALL)
select t.fresh();
select t.give(9, 'minecraft:cobblestone', 20); select t.give(10, 'minecraft:cobblestone', 30); select t.give(11, 'minecraft:cobblestone', 64); select t.give(12, 'minecraft:stick', 5);
select t.click(9, 0, 0);
select t.click(15, 0, 6);
select t.eq('a double click on an empty slot collects the same item from the other slots (the full stack only after the others), up to a full stack', t.carried(), 'cobblestone x64');
select t.eq('...the 64-stack was left alone in the first pass: 30 and 14 were taken from slots 10 and 11', t.slot(10) || ' / ' || t.slot(11), '- / cobblestone x50');

------------------------------------------------------------------------------------------------ the crafting grid: the result is recomputed and SENT on every change
select t.fresh();
select t.give(36, 'minecraft:oak_planks', 8);
select t.click(36, 0, 0);
select t.eq('a plank in the grid: the result slot update (a button), the cell, then the cursor', t.names(t.click(1, 1, 0)), array['container_set_slot', 'container_set_slot', 'set_cursor_item']);
select t.eq('...a button is the result', t.result(), 'oak_button x1');
select t.click(3, 1, 0);
select t.eq('two planks in a column: sticks in the result slot', t.result(), 'stick x4');
select t.click(36, 0, 0);
select t.eq('left click on the empty hotbar slot puts the remaining planks down', t.slot(36) || ' / ' || t.carried(), 'oak_planks x6 / -');
select t.eq('left click on the result: sticks on the cursor; one packet per consumed plank (a grid change each), then the refilled result', t.names(t.click(0, 0, 0)),
            array['container_set_slot', 'container_set_slot', 'container_set_slot', 'container_set_slot', 'set_cursor_item']);
select t.eq('...both planks are gone, the cursor holds the sticks, the result slot is empty again', t.slot(1) || ' ' || t.slot(3) || ' / ' || t.carried() || ' / ' || t.result(), '- - / stick x4 / -');

select t.fresh();
select t.give(9, 'minecraft:oak_log', 3);
select t.click(9, 0, 0); select t.click(1, 0, 0);
select t.eq('3 logs in one grid cell: 4 planks', t.result() || ' / ' || t.slot(1), 'oak_planks x4 / oak_log x3');
select t.click(0, 0, 1);
select t.eq('a shift click on the result crafts again and again until the grid cell is empty: 3 crafts, 12 planks, put into the LAST inventory slot (reverse order)', t.slot(44) || ' / ' || t.slot(1) || ' / ' || t.result(), 'oak_planks x12 / - / -');

------------------------------------------------------------------------------------------------ closing returns the grid and the cursor
select t.fresh();
select t.give(36, 'minecraft:oak_planks', 8);
select t.click(36, 0, 0); select t.click(1, 1, 0); select t.click(2, 1, 0);
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('container_close'), proto.varint(0));
truncate mc.play_out;
select mc.container_step(1001);
select t.eq('closing the inventory menu puts the grid cells and the carried planks back (the selected slot first)', t.slot(36) || ' / ' || t.slot(1) || ' ' || t.slot(2) || ' / ' || t.carried(), 'oak_planks x8 / - - / -');
select t.eq('...set_player_inventory for each slot that received items, then the inventory menu''s broadcast of what changed (the result slot, the two emptied grid cells, the hotbar slot), then the empty cursor (the carried planks went back too)', t.names(t.out()),
            array['set_player_inventory', 'set_player_inventory', 'set_player_inventory', 'container_set_slot', 'container_set_slot', 'container_set_slot', 'container_set_slot', 'set_cursor_item']);

------------------------------------------------------------------------------------------------ the crafting table: opening, crafting with remainders
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:crafting_table');
select t.use_item_on(2, -60, 0);
select mc.container_step(1002);
select t.eq('use_item_on a crafting table: open_screen, container_set_content, then the two block updates of the clicked block and the block beside the face', t.names(t.out()),
            array['open_screen', 'container_set_content', 'block_update', 'block_update']);
select t.eq('the click was taken out of the queue and acknowledged', (select count(*)::int from mc.play_in_work where packet_id = mc.sid('use_item_on')) || '/' || (select count(*)::int from mc.pending_ack where sequence = 5), '0/1');
select t.eq('the menu is the crafting table with container id 1, state id 1', (select kind || ' ' || container_id || ' ' || state_id from mc.menu_state where player = t.cid() and open), 'crafting 1 1');
-- cake (shaped 3x3): milk milk milk / sugar egg sugar / wheat wheat wheat; the buckets come back
select t.give(36, 'minecraft:milk_bucket', 1); select t.give(37, 'minecraft:milk_bucket', 1); select t.give(38, 'minecraft:milk_bucket', 1);
select t.give(39, 'minecraft:sugar', 1); select t.give(40, 'minecraft:egg', 1); select t.give(41, 'minecraft:sugar', 1);
select t.give(42, 'minecraft:wheat', 1); select t.give(43, 'minecraft:wheat', 1); select t.give(44, 'minecraft:wheat', 1);
-- (the crafting table's hotbar is menu slots 37-45 = inventory slots 36-44)
select t.click(37, 0, 0); select t.click(1, 0, 0); select t.click(38, 0, 0); select t.click(2, 0, 0); select t.click(39, 0, 0); select t.click(3, 0, 0);
select t.click(40, 0, 0); select t.click(4, 0, 0); select t.click(41, 0, 0); select t.click(5, 0, 0); select t.click(42, 0, 0); select t.click(6, 0, 0);
select t.click(43, 0, 0); select t.click(7, 0, 0); select t.click(44, 0, 0); select t.click(8, 0, 0); select t.click(45, 0, 0); select t.click(9, 0, 0);
select t.eq('the grid holds the cake recipe: a cake in the result slot', t.result(), 'cake x1');
select t.click(0, 0, 0);
select t.eq('taking it: the cake on the cursor, the milk buckets turn into buckets in their cells, the rest of the grid is empty', t.carried() || ' / ' || (select string_agg(coalesce(item, '-'), ' ' order by s) from generate_series(0, 8) s left join mc.menu_slot g on g.player = t.cid() and g.slot = s),
            'cake x1 / minecraft:bucket minecraft:bucket minecraft:bucket - - - - - -');
select mc.menu_do_close(t.cid(), true);
select t.eq('closing returns the three buckets to the inventory and the cake (the carried stack)', (select string_agg(replace(item, 'minecraft:', '') || ' x' || count, ' ' order by slot) from mc.inventory_slot where player = t.cid()), 'cake x1 bucket x3');
-- walking away closes it
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:crafting_table');
select t.eq('a block that is not a container does not open', mc.menu_open(t.cid(), 'minecraft:overworld', 0, -61, 0), false);
select t.eq('a crafting table opens', mc.menu_open(t.cid(), 'minecraft:overworld', 2, -60, 0), true);
update mc.player set x = 30.5 where uuid = t.cid();
truncate mc.play_out;
select mc.container_step(1003);
select t.eq('a player who walks out of range loses the menu (container_close for container id 1)', (select open from mc.menu_state where player = t.cid()) || ' ' || t.names(t.out())::text, 'false {container_close}');

------------------------------------------------------------------------------------------------ chests: contents, double chests, breaking
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:chest');
insert into mc.container_slot values ('minecraft:overworld', 2, -60, 0, 0, 'minecraft:cobblestone', 20, null), ('minecraft:overworld', 2, -60, 0, 26, 'minecraft:bucket', 3, null);
select t.give(36, 'minecraft:oak_planks', 10);
select t.eq('a chest has a block entity row once placed (for the chunk packets of later joiners)', (select type from mc.block_entity where x = 2 and y = -60 and z = 0), 'minecraft:chest');
select t.eq('it opens', mc.menu_open(t.cid(), 'minecraft:overworld', 2, -60, 0), true);
select t.eq('a single chest is a 9x3 menu; the player''s hotbar is menu slots 54-62', (select kind from mc.menu_state where player = t.cid() and open) || ' ' ||
            (select count(*)::int from mc.menu_slot_def where kind = 'generic_9x3' and idx between 54 and 62 and store = 'inv' and cs between 36 and 44), 'generic_9x3 9');
select t.click(0, 0, 0);
select t.eq('the cobblestone is picked up out of the chest', t.carried(), 'cobblestone x20');
select t.click(54, 0, 0);
select t.eq('...and swapped with the planks of hotbar slot 0 (menu slot 54)', t.slot(36) || ' / ' || t.carried(), 'cobblestone x20 / oak_planks x10');
select t.click(0, 0, 0);
select t.eq('...the planks are in the chest now', (select item || ' ' || count from mc.container_slot where x = 2 and slot = 0), 'minecraft:oak_planks 10');
select t.click(26, 0, 1);
select t.eq('shift click on a chest slot moves the stack into the player''s inventory, filling from the END (the last hotbar slot, reverse order)', t.slot(44), 'bucket x3');
-- breaking the chest: the contents are gone (no entity simulation here), the menu closes on the next tick
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:air');
select t.eq('breaking a chest removes its contents rows and its block entity', (select count(*)::int from mc.container_slot where x = 2 and y = -60 and z = 0) || '/' || (select count(*)::int from mc.block_entity where x = 2 and z = 0), '0/0');
select mc.container_step(1004);
select t.eq('the menu on it closes', (select open from mc.menu_state where player = t.cid()), false);

select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:chest[type=left,facing=north,waterlogged=false]'); select mc.set_block('minecraft:overworld', 3, -60, 0, 'minecraft:chest[type=right,facing=north,waterlogged=false]');
insert into mc.container_slot values ('minecraft:overworld', 3, -60, 0, 0, 'minecraft:cobblestone', 1, null), ('minecraft:overworld', 2, -60, 0, 0, 'minecraft:stick', 2, null);
select t.eq('a double chest opens from either half', mc.menu_open(t.cid(), 'minecraft:overworld', 2, -60, 0), true);
select t.eq('it is a 9x6 menu', (select kind from mc.menu_state where player = t.cid() and open), 'generic_9x6');
select t.click(27, 0, 0);
select t.eq('slot 27 is the LEFT half''s first slot (the RIGHT half, at 3,-60,0, holds slots 0-26: DoubleBlockCombiner)', t.carried(), 'stick x2');
select t.click(0, 0, 0);
select t.eq('slot 0 swaps with the right half''s first slot', t.carried() || ' / ' || (select item from mc.container_slot where x = 3 and slot = 0), 'cobblestone x1 / minecraft:stick');

------------------------------------------------------------------------------------------------ ender chest and barrel
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:ender_chest'); select mc.set_block('minecraft:overworld', 4, -60, 0, 'minecraft:barrel');
insert into mc.ender_slot values (t.cid(), 3, 'minecraft:diamond', 5, null);
select mc.menu_open(t.cid(), 'minecraft:overworld', 2, -60, 0);
select t.click(3, 0, 0);
select t.eq('the ender chest is the player''s own', t.carried(), 'diamond x5');
select t.click(-999, 0, 0);
select t.eq('a click outside throws the carried stack (no entity simulation here: it is gone)', t.carried() || ' / ' || (select count(*)::int from mc.ender_slot where player = t.cid()), '- / 0');
select mc.menu_do_close(t.cid(), true);
select mc.menu_open(t.cid(), 'minecraft:overworld', 4, -60, 0);
select t.eq('a barrel shows its open state while somebody looks into it', mc.get_block('minecraft:overworld', 4, -60, 0), 'minecraft:barrel[facing=north,open=true]');
select mc.menu_do_close(t.cid(), true);
select t.eq('...and closes again', mc.get_block('minecraft:overworld', 4, -60, 0), 'minecraft:barrel[facing=north,open=false]');

------------------------------------------------------------------------------------------------ furnaces (AbstractFurnaceBlockEntity.serverTick)
create or replace function t.ftick(p_n int) returns void language plpgsql as $$
declare i int;
begin for i in 1 .. p_n loop perform mc.furnace_step(1000 + i); end loop; end $$;
create or replace function t.fslot(p_slot int) returns text language sql as $$
  select coalesce((select replace(item, 'minecraft:', '') || ' x' || count from mc.container_slot where x = 2 and y = -60 and z = 0 and slot = p_slot), '-') $$;
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:furnace[facing=north,lit=false]');
select t.eq('opening a furnace sends open_screen, the contents and the four data values', (select mc.menu_open(t.cid(), 'minecraft:overworld', 2, -60, 0))::text || ' ' || t.names(t.out())::text,
            'true {open_screen,container_set_content,container_set_data,container_set_data,container_set_data,container_set_data}');
select mc.menu_do_close(t.cid(), false);
insert into mc.container_slot values ('minecraft:overworld', 2, -60, 0, 0, 'minecraft:raw_iron', 3, null), ('minecraft:overworld', 2, -60, 0, 1, 'minecraft:coal', 2, null);
select t.eq('slots written by SQL make the furnace tick: a row, the total 200 and the progress 0', (select cook_total || '/' || cook_progress from mc.furnace), '200/0');
select t.ftick(1);
select t.eq('the first tick consumes a coal, lights the furnace and counts one tick of cooking', (select lit_time || '/' || lit_duration || '/' || cook_progress from mc.furnace) || ' ' || t.fslot(1), '1600/1600/1 coal x1');
select t.eq('...and the block is lit', mc.get_block('minecraft:overworld', 2, -60, 0), 'minecraft:furnace[facing=north,lit=true]');
select t.ftick(198);
select t.eq('199 ticks: not done yet', t.fslot(0) || ' ' || t.fslot(2), 'raw_iron x3 -');
select t.ftick(1);
select t.eq('200 ticks: an iron ingot, one raw iron less', t.fslot(0) || ' ' || t.fslot(2), 'raw_iron x2 iron_ingot x1');
select t.eq('...the lit time counted down by 199 since it was set to 1600', (select lit_time from mc.furnace), 1401);
select t.ftick(200);
select t.eq('another 200 ticks: the second ingot', t.fslot(0) || ' ' || t.fslot(2), 'raw_iron x1 iron_ingot x2');
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:blast_furnace[facing=north,lit=false]');
insert into mc.container_slot values ('minecraft:overworld', 2, -60, 0, 0, 'minecraft:raw_iron', 2, null), ('minecraft:overworld', 2, -60, 0, 1, 'minecraft:coal', 1, null);
select t.ftick(1);
select t.eq('a blast furnace burns coal for 800 ticks (half) and cooks at double speed: total 100', (select lit_time || '/' || cook_total || '/' || speed from mc.furnace), '800/100/2');
select t.ftick(99);
select t.eq('...100 ticks per item', t.fslot(2) || ' ' || t.fslot(0), 'iron_ingot x1 raw_iron x1');
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:furnace[facing=north,lit=false]');
insert into mc.container_slot values ('minecraft:overworld', 2, -60, 0, 0, 'minecraft:raw_iron', 1, null), ('minecraft:overworld', 2, -60, 0, 1, 'minecraft:lava_bucket', 1, null);
select t.ftick(1);
select t.eq('a lava bucket leaves a bucket behind', t.fslot(1), 'bucket x1');
select t.ftick(199);
select t.eq('the single raw iron is done after 200 ticks: its slot is empty, the furnace still burns the rest of the lava', t.fslot(0) || ' ' || t.fslot(2) || ' ' || mc.get_block('minecraft:overworld', 2, -60, 0), '- iron_ingot x1 minecraft:furnace[facing=north,lit=true]');
select t.ftick(20000);
select t.eq('when the fuel is spent the furnace unlights (its row stays while the experience of the smelted items is waiting to be taken)', (select lit_time || ' ' || recipes_used::text from mc.furnace) || ' ' || mc.get_block('minecraft:overworld', 2, -60, 0), '0 {"minecraft:iron_ingot_from_smelting_raw_iron": 1} minecraft:furnace[facing=north,lit=false]');

-- the set-based fast path (mc.furnace.steady) must not change anything: two furnaces with the same contents, one of them forced onto the full per-furnace transcription at every tick
create or replace function t.ftick_pair(p_n int) returns void language plpgsql as $$
declare i int;
begin for i in 1 .. p_n loop update mc.furnace set steady = false where x = 4; perform mc.furnace_step(1000 + i); end loop; end $$;
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:furnace[facing=north,lit=false]');
select mc.set_block('minecraft:overworld', 4, -60, 0, 'minecraft:furnace[facing=north,lit=false]');
insert into mc.container_slot values ('minecraft:overworld', 2, -60, 0, 0, 'minecraft:raw_iron', 5, null), ('minecraft:overworld', 2, -60, 0, 1, 'minecraft:coal', 3, null),
                                     ('minecraft:overworld', 4, -60, 0, 0, 'minecraft:raw_iron', 5, null), ('minecraft:overworld', 4, -60, 0, 1, 'minecraft:coal', 3, null);
select t.ftick_pair(2);
select t.eq('the fast path is used: a steady furnace is flagged after its first full tick', (select steady from mc.furnace where x = 2), true);
select t.ftick_pair(1100);
select t.eq('1102 ticks: both furnaces are in the same state (lit time, progress, total, slots, the block)',
            (select string_agg(x::text, ',') from (select lit_time, lit_duration, cook_progress, cook_total, recipes_used::text, (select string_agg(slot || item || count, ';' order by slot) from mc.container_slot c where (c.x, c.y, c.z) = (f.x, f.y, f.z)) as slots,
                                                          mc.get_block('minecraft:overworld', f.x, f.y, f.z) like '%lit=true%' as lit from mc.furnace f where f.x = 2) x),
            (select string_agg(x::text, ',') from (select lit_time, lit_duration, cook_progress, cook_total, recipes_used::text, (select string_agg(slot || item || count, ';' order by slot) from mc.container_slot c where (c.x, c.y, c.z) = (f.x, f.y, f.z)) as slots,
                                                          mc.get_block('minecraft:overworld', f.x, f.y, f.z) like '%lit=true%' as lit from mc.furnace f where f.x = 4) x));
select t.eq('...and the smelting really happened (5 ingots)', (select count::int from mc.container_slot where x = 2 and slot = 2), 5);

------------------------------------------------------------------------------------------------ creative slot packets follow vanilla's validity rules
select t.fresh();
update mc.player set gamemode = 1 where uuid = t.cid();
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('set_creative_mode_slot'), proto.i16(36) || proto.varint(5) || proto.varint(mc.item_id('minecraft:water_bucket')) || '\x0000'::bytea);
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('set_creative_mode_slot'), proto.i16(37) || proto.varint(1) || proto.varint(mc.item_id('minecraft:water_bucket')) || '\x0000'::bytea);
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('set_creative_mode_slot'), proto.i16(0) || proto.varint(1) || proto.varint(mc.item_id('minecraft:stone')) || '\x0000'::bytea);
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('set_creative_mode_slot'), proto.i16(38) || proto.varint(64) || proto.varint(mc.item_id('minecraft:stone')) || '\x0000'::bytea);
select mc.apply_misc_input(1001);
select t.eq('five water buckets do not fit a stack of one (ignored), one does; slot 0 (the result) cannot be set; 64 stone is fine', t.slot(36) || ' ' || t.slot(37) || ' ' || t.slot(0) || ' ' || t.slot(38), '- water_bucket x1 - stone x64');

------------------------------------------------------------------------------------------------ a spectator only sees; leaving closes the menu
select t.fresh();
update mc.player set gamemode = 3 where uuid = t.cid();
select t.give(36, 'minecraft:stick', 1);
select t.eq('a spectator''s click is answered with the whole menu and changes nothing', t.names(t.click(36, 0, 0))::text || ' ' || t.slot(36), '{container_set_content} stick x1');
select t.fresh();
select t.give(36, 'minecraft:oak_planks', 4);
select t.click(36, 0, 0); select t.click(1, 1, 0);
update mc.player set conn_id = null where uuid = t.cid();
select t.eq('leaving puts the carried stack and the grid back into the inventory', t.slot(36) || ' / ' || t.slot(1) || ' / ' || t.carried(), 'oak_planks x4 / - / -');

------------------------------------------------------------------------------------------------ sneaking (player_input) with an item in the hand uses the item, not the block
select t.fresh();
select mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:crafting_table');
select t.give(36, 'minecraft:stick', 1);
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('player_input'), '\x20');
select t.use_item_on(2, -60, 0);
select mc.container_step(2001);
select t.eq('a sneaking player holding an item does not open the table: the click stays queued for the block code', (select count(*)::int from mc.play_in_work where packet_id = mc.sid('use_item_on')) || ' ' || (select sneaking from mc.player where uuid = t.cid()) || ' ' || coalesce((select open from mc.menu_state where player = t.cid()), false), '1 true false');
delete from mc.play_in_work;
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('player_input'), '\x00');
select t.use_item_on(2, -60, 0);
select mc.container_step(2002);
select t.eq('standing up, the same click opens it', (select sneaking from mc.player where uuid = t.cid()) || ' ' || (select open from mc.menu_state where player = t.cid()), 'false true');
select mc.menu_do_close(t.cid(), true);
update mc.player set held_slot = 4 where uuid = t.cid();
insert into mc.play_in_work (conn_id, packet_id, body) values (t.conn(), mc.sid('player_input'), '\x20');
select t.use_item_on(2, -60, 0);
select mc.container_step(2003);
select t.eq('sneaking with empty hands opens it (the stick is in another hotbar slot)', (select open from mc.menu_state where player = t.cid()), true);

------------------------------------------------------------------------------------------------ giving items (Inventory.add: the selected slot first, merging before filling)
select t.fresh();
select t.give(37, 'minecraft:stick', 60); select t.give(38, 'minecraft:bucket', 15);
select t.eq('/give: 10 sticks fill the stack of 60 (to 64) and the rest goes to the first empty hotbar slot', mc.inv_give(t.cid(), 'minecraft:stick', 10) || ' ' || t.slot(37) || ' ' || t.slot(36), '0 stick x64 stick x6');
select t.eq('...the player was sent one slot update per changed slot, in slot order, with state ids 2 and 3', t.names(t.out()) || array[t.state()::text], array['container_set_slot', 'container_set_slot', '3']);
select t.eq('buckets stack to 16: 20 more buckets fill one (to 16) and go into slots', mc.inv_give(t.cid(), 'minecraft:bucket', 20) || ' ' || t.slot(38) || ' ' || t.slot(39) || ' ' || t.slot(40), '0 bucket x16 bucket x16 bucket x3');
\else
\echo SKIP tests/sql/860_containers.sql: needs ref.recipe / ref.item_def (tools/load_recipes.py) and the static packets
\endif
