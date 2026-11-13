-- Mining (sql/840, 891, 892): the digging rules.  The table of (block, tool, ticks) below is what the REAL vanilla 26.3 server did (tests/e2e/mine_probe.py dig, recorded with
-- tests/e2e/vanilla_start.sh): per case a stop packet after w ticks was accepted and one after w - 1 ticks was refused (a case with w = 0 is mined at once by the start packet).
-- The test computes the same w from the jar's data (ref.block_mining, the tool rules of the item components, the block tags of the data pack) with mc.dig_progress and the rule
-- progress * (ticks + 1) >= 0.7, in float32.  Needs the mining data (tools/gen_mining.sh, tools/load_mining.py), the item components and the data pack tags.
select (select count(*) from ref.block_mining) > 0 and (select count(*) from ref.item_tool_block) > 0 as have_mining \gset
\if :have_mining
select mc.generate_flat('minecraft:overworld', x, z) from generate_series(-1, 1) x, generate_series(-1, 1) z;
delete from mc.player;
select mc.on_join(1, '00000000-0000-0000-0000-000000891001', 'Digger');
update mc.player set x = 0.5, y = -60, z = 0.5, on_ground = true where conn_id = 1;

create or replace function t.dig_w(p_state text, p_item text, p_on_ground boolean default true) returns int language plpgsql as $$
declare p mc.player; f real; j int := 0;
begin
  update mc.player set on_ground = p_on_ground where conn_id = 1;
  select * into p from mc.player where conn_id = 1;
  f := mc.dig_progress(p, p_item, p_state);
  if f >= 1::real then return 0; end if;
  loop
    exit when f * (j + 1)::real >= 0.7::real;
    j := j + 1; if j > 5000 then return null; end if;
  end loop;
  return j;
end $$;

-- (block, tool, w): recorded from the real server
select t.eq('vanilla dig ticks: ' || c.nm, t.dig_w(c.blk, c.tool), c.w)
  from (values
    ('dirt_hand', 'minecraft:dirt', null, 10), ('dirt_shovel_wood', 'minecraft:dirt', 'minecraft:wooden_shovel', 5), ('dirt_shovel_iron', 'minecraft:dirt', 'minecraft:iron_shovel', 1),
    ('stone_hand', 'minecraft:stone', null, 104), ('stone_pick_wood', 'minecraft:stone', 'minecraft:wooden_pickaxe', 15), ('stone_pick_stone', 'minecraft:stone', 'minecraft:stone_pickaxe', 7),
    ('stone_pick_iron', 'minecraft:stone', 'minecraft:iron_pickaxe', 5), ('stone_pick_diamond', 'minecraft:stone', 'minecraft:diamond_pickaxe', 3),
    ('stone_pick_gold', 'minecraft:stone', 'minecraft:golden_pickaxe', 2), ('stone_pick_netherite', 'minecraft:stone', 'minecraft:netherite_pickaxe', 3),
    ('cobble_pick_wood', 'minecraft:cobblestone', 'minecraft:wooden_pickaxe', 20), ('iron_ore_pick_wood', 'minecraft:iron_ore', 'minecraft:wooden_pickaxe', 104),
    ('iron_ore_pick_stone', 'minecraft:iron_ore', 'minecraft:stone_pickaxe', 15), ('diamond_ore_pick_iron', 'minecraft:diamond_ore', 'minecraft:iron_pickaxe', 10),
    ('obsidian_pick_diamond', 'minecraft:obsidian', 'minecraft:diamond_pickaxe', 131), ('log_hand', 'minecraft:oak_log[axis=y]', null, 41),
    ('log_axe_wood', 'minecraft:oak_log[axis=y]', 'minecraft:wooden_axe', 20), ('log_axe_iron', 'minecraft:oak_log[axis=y]', 'minecraft:iron_axe', 6),
    ('planks_axe_diamond', 'minecraft:oak_planks', 'minecraft:diamond_axe', 5), ('planks_pick_iron', 'minecraft:oak_planks', 'minecraft:iron_pickaxe', 41),
    ('wool_hand', 'minecraft:white_wool', null, 16), ('wool_shears', 'minecraft:white_wool', 'minecraft:shears', 3), ('leaves_hand', 'minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]', null, 4),
    ('leaves_shears', 'minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]', 'minecraft:shears', 0),
    ('leaves_sword', 'minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]', 'minecraft:iron_sword', 2), ('cobweb_sword', 'minecraft:cobweb', 'minecraft:iron_sword', 5),
    ('cobweb_shears', 'minecraft:cobweb', 'minecraft:shears', 5), ('cobweb_hand', 'minecraft:cobweb', null, 279), ('glass_hand', 'minecraft:glass', null, 6),
    ('sand_shovel_diamond', 'minecraft:sand', 'minecraft:diamond_shovel', 1), ('snow_block_shovel', 'minecraft:snow_block', 'minecraft:iron_shovel', 0),
    ('netherrack_pick_wood', 'minecraft:netherrack', 'minecraft:wooden_pickaxe', 4), ('hay_hoe', 'minecraft:hay_block[axis=y]', 'minecraft:diamond_hoe', 1),
    ('deepslate_pick_iron', 'minecraft:deepslate[axis=y]', 'minecraft:iron_pickaxe', 10), ('ladder_hand', 'minecraft:ladder[facing=north,waterlogged=false]', null, 8),
    ('torch_hand', 'minecraft:torch', null, 0), ('short_grass_hand', 'minecraft:short_grass', null, 0), ('stone_sword', 'minecraft:stone', 'minecraft:iron_sword', 104)
  ) c(nm, blk, tool, w);

-- the rules behind those numbers
select t.eq('stone with a hand: speed 1, the wrong tool (100)', array[mc.tool_speed(null, 'minecraft:stone')::text, mc.has_correct_tool(null, 'minecraft:stone')::text], array['1', 'false']);
select t.eq('stone with an iron pickaxe: speed 6, the correct tool (30)', array[mc.tool_speed('minecraft:iron_pickaxe', 'minecraft:stone')::text, mc.has_correct_tool('minecraft:iron_pickaxe', 'minecraft:stone')::text], array['6', 'true']);
select t.eq('iron ore needs a stone pickaxe: the wooden one is not the correct tool', array[mc.has_correct_tool('minecraft:wooden_pickaxe', 'minecraft:iron_ore')::text, mc.has_correct_tool('minecraft:stone_pickaxe', 'minecraft:iron_ore')::text], array['false', 'true']);
select t.eq('dirt needs no tool', mc.has_correct_tool(null, 'minecraft:dirt'), true);
select t.eq('a sword cuts cobwebs at 15 and everything else at 1', array[mc.tool_speed('minecraft:iron_sword', 'minecraft:cobweb')::text, mc.tool_speed('minecraft:iron_sword', 'minecraft:stone')::text], array['15', '1']);
select t.eq('hardness: stone 1.5, bedrock -1 (unbreakable: no progress), grass 0', array[mc.block_hardness('minecraft:stone')::text, mc.block_hardness('minecraft:bedrock')::text, mc.block_hardness('minecraft:short_grass')::text], array['1.5', '-1', '0']);
select t.eq('bedrock has no destroy progress', mc.dig_progress((select p from mc.player p where conn_id = 1), 'minecraft:diamond_pickaxe', 'minecraft:bedrock'), 0::real);
-- off the ground: a fifth of the speed (the player's on_ground flag)
select t.eq('dirt with a hand, falling: 52 ticks instead of 10', t.dig_w('minecraft:dirt', null, false), 52);

-- the durability of the held tool: the stack's component patch, as the real server sent it (container_set_slot after a stone dig: iron pickaxe with damage 1 = 01 00 03 01)
select t.eq('damage patch of 1 (vanilla: iron pickaxe after one block)', mc.damage_patch(1), '01000301');
select t.eq('damage patch of 0 is no patch', mc.damage_patch(0), null);
select t.eq('damage of the patch 01000302', mc.patch_damage('01000302'), 2);
select t.eq('damage of the empty patch', mc.patch_damage('0000'), 0);
select t.eq('a patch with other components: unknown', mc.patch_damage('0100150102'), null);

-- the loot of a block: stone drops cobblestone, a wheat plant of age 7 wheat and seeds, ore raw metal, a double slab two slabs, leaves nothing without shears or luck
select t.eq('stone drops cobblestone', (select array_agg(item || ' ' || cnt) from mc.loot_roll((select loot from ref.block_loot where block = 'minecraft:stone'), 'minecraft:stone', 'minecraft:iron_pickaxe', 0, 0, 0)), array['minecraft:cobblestone 1']);
select t.eq('iron ore drops raw iron', (select array_agg(item) from mc.loot_roll((select loot from ref.block_loot where block = 'minecraft:iron_ore'), 'minecraft:iron_ore', 'minecraft:stone_pickaxe', 0, 0, 0)), array['minecraft:raw_iron']);
select t.eq('a double slab drops two slabs', (select array_agg(item || ' ' || cnt) from mc.loot_roll((select loot from ref.block_loot where block = 'minecraft:oak_slab'), 'minecraft:oak_slab[type=double,waterlogged=false]', null, 0, 0, 0)), array['minecraft:oak_slab 2']);
select t.eq('a single slab drops one', (select array_agg(item || ' ' || cnt) from mc.loot_roll((select loot from ref.block_loot where block = 'minecraft:oak_slab'), 'minecraft:oak_slab[type=bottom,waterlogged=false]', null, 0, 0, 0)), array['minecraft:oak_slab 1']);
select t.eq('leaves cut with shears drop themselves', (select array_agg(item) from mc.loot_roll((select loot from ref.block_loot where block = 'minecraft:oak_leaves'), 'minecraft:oak_leaves[distance=1,persistent=false,waterlogged=false]', 'minecraft:shears', 0, 0, 0)), array['minecraft:oak_leaves']);
select t.eq('a ripe wheat plant drops wheat and at least one seed', (select array_agg(item order by item) filter (where item in ('minecraft:wheat', 'minecraft:wheat_seeds')) from mc.loot_roll((select loot from ref.block_loot where block = 'minecraft:wheat'), 'minecraft:wheat[age=7]', null, 0, 0, 0)), array['minecraft:wheat', 'minecraft:wheat_seeds']);
select t.eq('bedrock and other blocks without a table drop nothing', (select count(*) from mc.loot_roll(null, 'minecraft:bedrock', null, 0, 0, 0)), 0::bigint);

-- the block loot tables: 1,201 of the jar
select t.is_true('the block loot tables are loaded', (select count(*) from ref.block_loot) > 1000);
\else
\echo 'NOTE: no mining data: tests/sql/891_mining.sql skipped'
\endif
