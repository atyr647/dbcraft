-- Mining, part 3: what a broken block drops (docs/MINING-AND-COMMANDS.md).  Block.dropResources: the block's loot table (ref.block_loot, the jar's data/minecraft/loot_table/blocks) is
-- rolled with the block's state and the player's tool, and every resulting stack is spawned as an item entity at the block (Block.popResource).  Items are ENTITIES in vanilla, so
-- this only happens with dbcraft.entity-mode = inline (like the items a closed chest or a death would drop, sql/863 / 865); with the entity simulation off the blocks drop nothing.
-- The game rule block_drops is honoured.
--
-- The interpreter covers the constructs the 1,201 block tables of 26.3 use:
--   entries      item, alternatives (the first child whose conditions hold), dynamic (shulker box contents: nothing)
--   conditions   survives_explosion (always: there is no explosion), match_block (block, list or #tag, with the state's properties), match_tool (items, enchantment levels),
--                location_check (the block at an offset), table_bonus (the fortune table at level 0), random_chance, entity_properties (the digger exists), any_of / all_of /
--                inverted, and the predicates tool/can_shear (the tool is shears) and tool/can_silk_touch
--   modifiers    set_count (constant, uniform, binomial; with its own condition), apply_bonus at fortune level 0 (ore_drops, uniform_bonus_count, binomial_with_bonus_count: the
--                last still adds binomial(extra, probability)), limit_count, explosion_decay (nothing without an explosion); copy_components and copy_state add item components
--                that are not modelled: ignored
-- NOT modelled: enchantments of the tool (silk touch is never true, fortune is 0: item components other than the damage are not decoded), luck, experience orbs of ores, drops of
-- block entities' contents (a chest's items are the container module's, sql/865), and the loot tables of mobs and chests.  A table with a construct that is not listed drops nothing
-- (raise notice) instead of something wrong.

-- NumberProvider.getInt: constant, uniform (float, rounded), binomial; a plain number is a constant
create or replace function mc.loot_int(v jsonb) returns int language plpgsql volatile as $$
declare t text; n int; k int; c int := 0;
begin
  if v is null then return 0; end if;
  if jsonb_typeof(v) = 'number' then return round((v #>> '{}')::numeric)::int; end if;
  t := coalesce(v ->> 'type', 'minecraft:constant');
  if t = 'minecraft:constant' then return round((v ->> 'value')::numeric)::int;
  elsif t = 'minecraft:uniform' then return round(((v ->> 'min')::float8 + random() * ((v ->> 'max')::float8 - (v ->> 'min')::float8))::numeric)::int;
  elsif t = 'minecraft:binomial' then
    n := mc.loot_int(v -> 'n'); for k in 1 .. n loop if random() < (v ->> 'p')::float8 or ((v -> 'p') ->> 'value') is not null and random() < ((v -> 'p') ->> 'value')::float8 then c := c + 1; end if; end loop; return c;
  end if;
  raise notice 'mc.loot_int: unsupported number provider %', t; return 0;
end $$;

-- a block predicate's `blocks` (a block id, a list or a #tag) against a state name
create or replace function mc.loot_blocks_match(p_blocks jsonb, p_state text) returns boolean language plpgsql stable as $$
declare e jsonb; nm text := split_part(p_state, '[', 1);
begin
  if p_blocks is null then return true; end if;
  for e in select * from jsonb_array_elements(case when jsonb_typeof(p_blocks) = 'array' then p_blocks else jsonb_build_array(p_blocks) end) loop
    if (e #>> '{}') like '#%' then
      if exists (select 1 from ref.dp_tag_member t where t.registry = 'minecraft:block' and t.tag = substr(e #>> '{}', 2) and t.member = nm) then return true; end if;
    elsif (e #>> '{}') = nm then return true; end if;
  end loop;
  return false;
end $$;

-- a state predicate ({property: "value"} or {property: {min, max}}) against a state name's properties
create or replace function mc.loot_state_match(p_pred jsonb, p_state text) returns boolean language plpgsql stable as $$
declare k text; v jsonb; actual text;
begin
  if p_pred is null then return true; end if;
  for k, v in select * from jsonb_each(p_pred) loop
    actual := substring(p_state from '[\[,]' || k || '=([^,\]]*)');
    if actual is null then return false; end if;
    if jsonb_typeof(v) = 'object' then
      if v ? 'min' and actual::numeric < (v ->> 'min')::numeric then return false; end if;
      if v ? 'max' and actual::numeric > (v ->> 'max')::numeric then return false; end if;
    elsif actual <> (v #>> '{}') then return false; end if;
  end loop;
  return true;
end $$;

-- ItemPredicate (the tool): `items` (an item id, a list or a #tag) and the enchantment requirements (no enchantments are known: a requirement of level >= 1 fails)
create or replace function mc.loot_item_match(p_pred jsonb, p_tool text) returns boolean language plpgsql stable as $$
declare e jsonb; ok boolean := p_pred -> 'items' is null; en jsonb;
begin
  if p_pred ? 'items' then
    for e in select * from jsonb_array_elements(case when jsonb_typeof(p_pred -> 'items') = 'array' then p_pred -> 'items' else jsonb_build_array(p_pred -> 'items') end) loop
      if (e #>> '{}') like '#%' then
        if p_tool is not null and exists (select 1 from ref.dp_tag_member t where t.registry = 'minecraft:item' and t.tag = substr(e #>> '{}', 2) and t.member = p_tool) then ok := true; end if;
      elsif p_tool is not null and (e #>> '{}') = p_tool then ok := true; end if;
    end loop;
  end if;
  if not ok then return false; end if;
  for en in select * from jsonb_array_elements(coalesce(p_pred #> '{predicates,minecraft:enchantments}', '[]')) loop
    if coalesce((en #>> '{levels,min}')::int, 0) >= 1 then return false; end if;
  end loop;
  return true;
end $$;

create or replace function mc.loot_cond(c jsonb, p_state text, p_tool text, bx int, yy int, bz int) returns boolean language plpgsql volatile as $$
declare t text; term jsonb; r boolean; off_state text; chances jsonb; lvl int := 0; ch float8;
begin
  if c is null then return true; end if;
  if jsonb_typeof(c) = 'string' then
    case c #>> '{}'
      when 'minecraft:tool/can_shear' then return p_tool = 'minecraft:shears';
      when 'minecraft:tool/can_silk_touch' then return false;                                  -- (enchantments are not modelled)
      else raise notice 'mc.loot_cond: unknown predicate %', c #>> '{}'; return false;
    end case;
  end if;
  t := c ->> 'type';
  case t
    when 'minecraft:survives_explosion' then return true;
    when 'minecraft:entity_properties' then return true;
    when 'minecraft:inverted' then return not mc.loot_cond(c -> 'term', p_state, p_tool, bx, yy, bz);
    when 'minecraft:all_of' then
      for term in select * from jsonb_array_elements(c -> 'terms') loop if not mc.loot_cond(term, p_state, p_tool, bx, yy, bz) then return false; end if; end loop; return true;
    when 'minecraft:any_of' then
      for term in select * from jsonb_array_elements(c -> 'terms') loop if mc.loot_cond(term, p_state, p_tool, bx, yy, bz) then return true; end if; end loop; return false;
    when 'minecraft:match_block' then return mc.loot_blocks_match(c -> 'blocks', p_state) and mc.loot_state_match(c -> 'state', p_state);
    when 'minecraft:match_tool' then return mc.loot_item_match(c -> 'predicate', p_tool);
    when 'minecraft:location_check' then
      off_state := coalesce(mc.get_block('minecraft:overworld', bx + coalesce((c ->> 'offsetX')::int, 0), yy + coalesce((c ->> 'offsetY')::int, 0), bz + coalesce((c ->> 'offsetZ')::int, 0)), 'minecraft:air');
      return mc.loot_blocks_match(c #> '{predicate,block,blocks}', off_state) and mc.loot_state_match(c #> '{predicate,block,state}', off_state);
    when 'minecraft:table_bonus' then
      chances := c -> 'chances'; ch := (chances ->> least(lvl, jsonb_array_length(chances) - 1))::float8; return random() < ch;
    when 'minecraft:random_chance' then
      ch := case when jsonb_typeof(c -> 'chance') = 'number' then (c ->> 'chance')::float8 else (c #>> '{chance,value}')::float8 end; return random() < ch;
    else raise notice 'mc.loot_cond: unsupported condition %', t; return false;
  end case;
end $$;

-- LootItemFunction: the modifiers of an entry / pool / table applied to a count (the item stays)
create or replace function mc.loot_modify(p_mods jsonb, p_count int, p_state text, p_tool text, bx int, yy int, bz int) returns int language plpgsql volatile as $$
declare f jsonb; t text; n int := p_count; lvl int := 0; extra int; k int; p float8; mult int; lim jsonb;
begin
  if p_mods is null then return n; end if;
  for f in select * from jsonb_array_elements(case when jsonb_typeof(p_mods) = 'array' then p_mods else jsonb_build_array(p_mods) end) loop
    continue when jsonb_typeof(f) = 'string';
    continue when f ? 'condition' and not mc.loot_cond(f -> 'condition', p_state, p_tool, bx, yy, bz);
    t := f ->> 'type';
    case t
      when 'minecraft:set_count' then n := case when coalesce((f ->> 'add')::boolean, false) then n else 0 end + mc.loot_int(f -> 'count');
      when 'minecraft:explosion_decay' then null;
      when 'minecraft:copy_components', 'minecraft:copy_state', 'minecraft:set_components', 'minecraft:set_name', 'minecraft:set_lore' then null;
      when 'minecraft:limit_count' then
        lim := f -> 'limit'; if lim ? 'min' then n := greatest(n, mc.loot_int(lim -> 'min')); end if; if lim ? 'max' then n := least(n, mc.loot_int(lim -> 'max')); end if;
      when 'minecraft:apply_bonus' then
        case f ->> 'formula'
          when 'minecraft:ore_drops' then null;                                                    -- count + random(max(0, nextInt(level + 2) - 1)): nothing at level 0
          when 'minecraft:uniform_bonus_count' then null;                                          -- count + nextInt(multiplier * level + 1): nothing at level 0
          when 'minecraft:binomial_with_bonus_count' then
            extra := (f #>> '{parameters,extra}')::int; p := (f #>> '{parameters,probability}')::float8;
            for k in 1 .. lvl + extra loop if random() < p then n := n + 1; end if; end loop;
          else raise notice 'mc.loot_modify: unsupported bonus formula %', f ->> 'formula';
        end case;
      else raise notice 'mc.loot_modify: unsupported function %', t;
    end case;
  end loop;
  return n;
end $$;

-- LootPoolEntryContainer.expand: the item an entry yields, or null (a failed condition, nothing to give)
create or replace function mc.loot_entry(e jsonb, p_state text, p_tool text, bx int, yy int, bz int, out item text, out cnt int) language plpgsql volatile as $$
declare ch jsonb; sub record;
begin
  item := null; cnt := 0;
  if not mc.loot_cond(e -> 'condition', p_state, p_tool, bx, yy, bz) then return; end if;
  case e ->> 'type'
    when 'minecraft:item' then item := e ->> 'name'; cnt := 1;
    when 'minecraft:alternatives' then
      for ch in select * from jsonb_array_elements(e -> 'children') loop
        select * into sub from mc.loot_entry(ch, p_state, p_tool, bx, yy, bz);
        if sub.item is not null then item := sub.item; cnt := sub.cnt; exit; end if;
      end loop;
    when 'minecraft:dynamic' then return;
    else raise notice 'mc.loot_entry: unsupported entry %', e ->> 'type'; return;
  end case;
  if item is not null then cnt := mc.loot_modify(e -> 'modifier', cnt, p_state, p_tool, bx, yy, bz); end if;
end $$;

-- LootTable.getRandomItems: the stacks a block's table gives for this state and tool (counts above 0 only, merged by nothing: one stack per roll)
create or replace function mc.loot_roll(p_loot jsonb, p_state text, p_tool text, bx int, yy int, bz int) returns table (item text, cnt int) language plpgsql volatile as $$
declare pool jsonb; rolls int; r int; ents jsonb[]; es record; e jsonb; total float8; pick float8; acc float8; chosen record; n int; w float8; ws float8[]; i int;
begin
  for pool in select * from jsonb_array_elements(coalesce(p_loot -> 'pools', '[]')) loop
    continue when not mc.loot_cond(pool -> 'condition', p_state, p_tool, bx, yy, bz);
    rolls := mc.loot_int(pool -> 'rolls');
    for r in 1 .. rolls loop
      ents := '{}'; ws := '{}'; total := 0;
      for e in select * from jsonb_array_elements(pool -> 'entries') loop
        select * into es from mc.loot_entry(e, p_state, p_tool, bx, yy, bz);
        continue when es.item is null;
        w := coalesce((e ->> 'weight')::float8, 1); ents := ents || e; ws := ws || w; total := total + w;
        if jsonb_array_length(pool -> 'entries') = 1 then chosen := es; end if;
      end loop;
      continue when cardinality(ents) = 0 or total <= 0;
      if cardinality(ents) > 1 then                                                               -- LootPool.addRandomItem: one entry by weight
        pick := random() * total; acc := 0;
        for i in 1 .. cardinality(ents) loop
          acc := acc + ws[i];
          if pick < acc then select * into chosen from mc.loot_entry(ents[i], p_state, p_tool, bx, yy, bz); exit; end if;
        end loop;
      end if;
      n := mc.loot_modify(pool -> 'modifier', chosen.cnt, p_state, p_tool, bx, yy, bz);
      n := mc.loot_modify(p_loot -> 'modifier', n, p_state, p_tool, bx, yy, bz);
      if n > 0 then item := chosen.item; cnt := n; return next; end if;
    end loop;
  end loop;
end $$;

-- Block.dropResources -> Block.popResource: an item entity at the block's centre (+- 0.25), pickup delay 10 ticks, the velocity ItemEntity's constructor gives
create or replace function mc.block_drops(p mc.player, bx int, yy int, bz int, p_state text, p_tool text) returns void language plpgsql as $$
declare l jsonb; d record; left_ int; chunk int;
begin
  if mc.entity_mode() <> 'inline' or not mc.gamerule_bool('block_drops') then return; end if;
  select loot into l from ref.block_loot where block = split_part(p_state, '[', 1);
  if l is null then return; end if;
  for d in select * from mc.loot_roll(l, p_state, p_tool, bx, yy, bz) loop
    left_ := d.cnt;
    while left_ > 0 loop
      chunk := least(left_, mc.s_max(d.item)); left_ := left_ - chunk;
      perform mc.entity_spawn('minecraft:item', bx + 0.5 + (random() - 0.5) * 0.5, yy + 0.5 + (random() - 0.5) * 0.5 - 0.125, bz + 0.5 + (random() - 0.5) * 0.5,
                              random() * 0.2 - 0.1, 0.2, random() * 0.2 - 0.1, null, jsonb_build_object('item', d.item, 'count', chunk), 10);
    end loop;
  end loop;
end $$;
