-- Mining, part 1: the reference data of digging (docs/MINING-AND-COMMANDS.md).  Everything here is read from the pinned 26.3 server jar by tools/gen_mining.sh and loaded by
-- tools/load_mining.py; without it a block has hardness 0 (breaks at once) and every item digs like a hand.
--
--   ref.block_mining      per block: BlockState.getDestroySpeed (hardness, -1 unbreakable) and requiresCorrectToolForDrops.  The dump found no block state whose values differ
--                         from its block's default state and no block class that overrides getDestroyProgress, so a block name is the whole key
--   ref.item_tool         per item with a `minecraft:tool` component: default mining speed, damage per block, whether it may break blocks in creative (swords may not), max damage
--   ref.item_tool_rule    the component's rules as the data lists them: a block, a list entry or `#tag`, the speed (null = not a speed rule), correct_for_drops (null = not a drops rule)
--   ref.item_tool_block   the rules expanded to one row per block (ref.item_tool_expand, from ref.dp_tag_member), so a lookup is a primary-key probe
--   ref.block_loot        the block loot tables of the jar (data/minecraft/loot_table/blocks), as JSON

create table if not exists ref.block_mining (block text primary key, hardness real not null, requires_tool boolean not null);
create table if not exists ref.item_tool (item text primary key, default_speed real not null, damage_per_block int not null, creative_ok boolean not null, max_damage int);
create table if not exists ref.item_tool_rule (item text not null, ord int not null, spec text not null, speed real, correct boolean, primary key (item, ord, spec));
create table if not exists ref.item_tool_block (item text not null, block text not null, ord int not null, speed real, correct boolean, primary key (item, block, ord));
create table if not exists ref.block_loot (block text primary key, loot jsonb not null);

-- Tool.getMiningSpeed / isCorrectForDrops test the rules IN ORDER with BlockState.is(HolderSet): a rule is a block, a list of blocks or a tag.
create or replace function ref.item_tool_expand() returns void language plpgsql as $$
begin
  truncate ref.item_tool_block;
  insert into ref.item_tool_block (item, block, ord, speed, correct)
    select r.item, r.spec, r.ord, r.speed, r.correct from ref.item_tool_rule r where r.spec not like '#%'
    on conflict do nothing;
  insert into ref.item_tool_block (item, block, ord, speed, correct)
    select r.item, m.member, r.ord, r.speed, r.correct from ref.item_tool_rule r
      join ref.dp_tag_member m on m.registry = 'minecraft:block' and m.tag = substr(r.spec, 2) where r.spec like '#%'
    on conflict do nothing;
end $$;

-- BlockState.getDestroySpeed(level, pos): the hardness of the block of a state name (air and unknown blocks 0)
create or replace function mc.block_hardness(p_state text) returns real language sql stable parallel safe as $$
  select coalesce((select hardness from ref.block_mining where block = split_part(p_state, '[', 1)), 0::real) $$;

create or replace function mc.block_requires_tool(p_state text) returns boolean language sql stable parallel safe as $$
  select coalesce((select requires_tool from ref.block_mining where block = split_part(p_state, '[', 1)), false) $$;

-- Item.getDestroySpeed: Tool.getMiningSpeed (the first rule with a speed that names the block, else the tool's default speed); an item without a tool component: 1
create or replace function mc.tool_speed(p_item text, p_state text) returns real language sql stable parallel safe as $$
  select coalesce(
    (select b.speed from ref.item_tool_block b where b.item = p_item and b.block = split_part(p_state, '[', 1) and b.speed is not null order by b.ord limit 1),
    (select t.default_speed from ref.item_tool t where t.item = p_item),
    1::real) $$;

-- Item.isCorrectToolForDrops: Tool.isCorrectForDrops (the first rule with a drops flag that names the block; none: false); an item without a tool component: false
create or replace function mc.tool_correct(p_item text, p_state text) returns boolean language sql stable parallel safe as $$
  select coalesce((select b.correct from ref.item_tool_block b where b.item = p_item and b.block = split_part(p_state, '[', 1) and b.correct is not null order by b.ord limit 1), false) $$;

-- Player.hasCorrectToolForDrops: a block that does not require the correct tool is always "correct"
create or replace function mc.has_correct_tool(p_item text, p_state text) returns boolean language sql stable parallel safe as $$
  select not mc.block_requires_tool(p_state) or mc.tool_correct(p_item, p_state) $$;
