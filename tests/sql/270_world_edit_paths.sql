-- The fast single-edit path (mc.set_block) must leave exactly the rows the general path (mc.edit_section) leaves, whatever the sequence of edits:
-- same sections (palette, bits, packed data, counts), same heightmaps, same versions, same events.  Two dimensions with the same layers; the same
-- pseudo-random edits go through set_block on one and through edit_section on the other.  The edits cover: new sections, palette growth within a bit
-- width and past it (4 -> 5 bits), air (breaking), blocks above the surface (heightmap raises), non-collidable blocks, leaves, water, bare block names.
\! python3 tools/load_world_ref.py

insert into mc.dimension (name) values ('dbcraft:e1'), ('dbcraft:e2');
insert into mc.flat_layer (dimension, y, block)
select d, y, b from (values ('dbcraft:e1'), ('dbcraft:e2')) dd(d),
     (values (-64, 'minecraft:bedrock'), (-63, 'minecraft:dirt'), (-62, 'minecraft:dirt'), (-61, 'minecraft:grass_block')) l(y, b);
select mc.generate_flat('dbcraft:e1', 0, 0);
select mc.generate_flat('dbcraft:e1', 1, 0);
select mc.generate_flat('dbcraft:e2', 0, 0);
select mc.generate_flat('dbcraft:e2', 1, 0);
truncate mc.block_event;

create temp table edits (n int primary key, x int, y int, z int, block text);
select setseed(0.31);
insert into edits
select n, (random() * 31)::int, -64 + (random() * 63)::int, (random() * 15)::int,
       (array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand','minecraft:glass','minecraft:oak_planks','minecraft:oak_leaves',
              'minecraft:torch','minecraft:water','minecraft:lava','minecraft:cobblestone','minecraft:granite','minecraft:diorite','minecraft:andesite',
              'minecraft:sandstone','minecraft:red_sand','minecraft:clay','minecraft:netherrack','minecraft:obsidian','minecraft:glowstone',
              'minecraft:oak_log','minecraft:birch_log','minecraft:spruce_log','minecraft:jungle_log','minecraft:air','minecraft:air','minecraft:air',
              'minecraft:short_grass'])[1 + (random() * 27)::int]
  from generate_series(1, 4000) n;
-- a few bare block names (their default state) and repeated edits of one position
insert into edits values (5001, 3, -50, 3, 'minecraft:stone'), (5002, 3, -50, 3, 'minecraft:stone'), (5003, 3, -50, 3, 'minecraft:air'), (5004, 3, -50, 3, 'minecraft:air'),
                         (5005, 4, -20, 4, 'minecraft:oak_log'), (5006, 4, -20, 4, 'minecraft:oak_log[axis=x]');

select t.eq('the same edits through the fast path: count of changes', (select count(*) filter (where mc.set_block('dbcraft:e1', x, y, z, block))::int from (select * from edits order by n) q), (
    select count(*) filter (where mc.edit_section('dbcraft:e2', x >> 4, y >> 4, z >> 4, array[mc.section_idx(x, y, z)], array[block]) > 0)::int from (select * from edits order by n) q));

create function pg_temp.dim_fp(p_dim text) returns table (what text, fp text) language sql stable as $$
  select 'sections', md5(coalesce(string_agg(concat_ws('|', cx, cz, sy, block_count, fluid_count, palette::text, bits, encode(data, 'hex')), ';' order by cx, cz, sy), ''))
    from mc.chunk_section where dimension = p_dim
  union all
  select 'chunks', md5(coalesce(string_agg(concat_ws('|', cx, cz, version, dirty, hm_dirty, hm_motion_blocking::text, hm_motion_blocking_no_leaves::text, hm_world_surface::text), ';' order by cx, cz), ''))
    from mc.chunk where dimension = p_dim
  union all
  select 'events', md5(coalesce(string_agg(concat_ws('|', x, y, z, old_state, new_state), ';' order by id), ''))
    from mc.block_event where dimension = p_dim $$;

select t.eq('sections identical (palette, bits, packed data, counts)', (select fp from pg_temp.dim_fp('dbcraft:e1') where what = 'sections'), (select fp from pg_temp.dim_fp('dbcraft:e2') where what = 'sections'));
select t.eq('chunk rows identical (versions, dirty flags, the three heightmaps)', (select fp from pg_temp.dim_fp('dbcraft:e1') where what = 'chunks'), (select fp from pg_temp.dim_fp('dbcraft:e2') where what = 'chunks'));
select t.eq('events identical, in order', (select fp from pg_temp.dim_fp('dbcraft:e1') where what = 'events'), (select fp from pg_temp.dim_fp('dbcraft:e2') where what = 'events'));
select t.is_true('the test is not trivial: thousands of events, sections that grew past 16 palette entries, new sections created',
    (select count(*) > 3000 from mc.block_event where dimension = 'dbcraft:e1')
    and (select max(cardinality(palette)) > 16 from mc.chunk_section where dimension = 'dbcraft:e1')
    and (select count(*) >= 8 from mc.chunk_section where dimension = 'dbcraft:e1'));
select t.is_true('...and some sections use more than 4 bits (the width-change path ran)', (select max(bits) > 4 from mc.chunk_section where dimension = 'dbcraft:e1'));

-- the incremental heightmaps equal a full recompute
create temp table hm_before as select cx, cz, hm_motion_blocking mb, hm_motion_blocking_no_leaves nl, hm_world_surface ws from mc.chunk where dimension = 'dbcraft:e1';
update mc.chunk set hm_dirty = true where dimension = 'dbcraft:e1';
select mc.ensure_chunk_current('dbcraft:e1', 0, 0);
select mc.ensure_chunk_current('dbcraft:e1', 1, 0);
select t.eq('incremental heightmaps == full recompute (both chunks, all three kinds)',
    (select count(*)::int from mc.chunk c join hm_before b on b.cx = c.cx and b.cz = c.cz
      where c.dimension = 'dbcraft:e1' and (c.hm_motion_blocking <> b.mb or c.hm_motion_blocking_no_leaves <> b.nl or c.hm_world_surface <> b.ws)), 0);

-- the packets built from both are identical too
select t.eq('chunk packets identical', md5(mc.chunk_packet('dbcraft:e1', 0, 0)), md5(mc.chunk_packet('dbcraft:e2', 0, 0)));

-- single behaviours of the fast path
select mc.set_block('dbcraft:e1', 9, -61, 9, 'minecraft:grass_block');
create temp table ev0 as select count(*) c from mc.block_event where dimension = 'dbcraft:e1';
select t.is_true('setting the block that is already there is a no-change (false)', not mc.set_block('dbcraft:e1', 9, -61, 9, 'minecraft:grass_block'));
select t.eq('...and queues no event', (select count(*)::int from mc.block_event where dimension = 'dbcraft:e1'), (select c::int from ev0));
select t.is_true('a bare block name is an edit', mc.set_block('dbcraft:e1', 10, -61, 10, 'minecraft:oak_log'));
select t.eq('...and resolves to the default state', mc.get_block('dbcraft:e1', 10, -61, 10), 'minecraft:oak_log[axis=y]');
create temp table before_fail as select mc.get_block('dbcraft:e1', 1, -61, 1) as b;
select t.raises('an unknown block name raises', $$select mc.set_block('dbcraft:e1', 1, -61, 1, 'minecraft:no_such_block')$$);
select t.raises('an unknown dimension raises', $$select mc.set_block('dbcraft:nope', 1, -61, 1, 'minecraft:stone')$$);
select t.raises('a position outside the world raises', $$select mc.set_block('dbcraft:e1', 1, 5000, 1, 'minecraft:stone')$$);
select t.eq('the failed edits changed nothing', mc.get_block('dbcraft:e1', 1, -61, 1), (select b from before_fail));
select t.is_true('an edit in a chunk that does not exist yet succeeds', mc.set_block('dbcraft:e1', 16 * 77 + 1, -30, 1, 'minecraft:stone'));
select t.eq('...and creates the chunk and the block', (select count(*)::int from mc.chunk where dimension = 'dbcraft:e1' and cx = 77), 1);
select t.eq('...with the block in place', mc.get_block('dbcraft:e1', 16 * 77 + 1, -30, 1), 'minecraft:stone');
