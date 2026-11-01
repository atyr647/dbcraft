-- mc.set_blocks (sql/290, one set-based pass) must leave exactly the rows the original per-section loop (mc_old.set_blocks, generated from commit 971e8cb by
-- tests/bench/edit/make_old_impl.py) leaves: same sections (palette, bits, packed data, counts), same chunk rows (version, dirty flag, the three heightmaps), the same
-- block events in the same order, the same return value, the same packets.  Two dimensions with the same layers; every batch goes through the new function on one and
-- through the old one on the other.  The batches cover: random mixes with palette growth through every bit width (4 -> 5 -> 6 bits), the global palette (hundreds of
-- distinct states) and edits inside a global section, repeated edits of the same position (sequential semantics: events and counts), missing sections and chunks,
-- negative coordinates, edits across section and chunk borders, bare block names, no-op batches, air edits that remove column tops (heightmap rescans), non-collidable
-- blocks and leaves, batches of 8 and 9 edits (either side of the threshold between the two paths), and the error cases.
\! python3 tools/load_world_ref.py
\ir ../bench/edit/old_impl.sql

insert into mc.dimension (name) values ('dbcraft:b1'), ('dbcraft:b2');
insert into mc.flat_layer (dimension, y, block)
select d, y, b from (values ('dbcraft:b1'), ('dbcraft:b2')) dd(d),
     (values (-64, 'minecraft:bedrock'), (-63, 'minecraft:dirt'), (-62, 'minecraft:dirt'), (-61, 'minecraft:grass_block')) l(y, b);
select mc.generate_flat_area('dbcraft:b1', 0, 0, 3, 1);
select mc.generate_flat_area('dbcraft:b2', 0, 0, 3, 1);
truncate mc.block_event;

create temp table batches (bn int, o int, x int, y int, z int, block text);
select setseed(0.77);
create temp table names as select array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand','minecraft:glass','minecraft:oak_planks','minecraft:oak_leaves',
              'minecraft:torch','minecraft:water','minecraft:lava','minecraft:cobblestone','minecraft:granite','minecraft:diorite','minecraft:andesite',
              'minecraft:sandstone','minecraft:red_sand','minecraft:clay','minecraft:netherrack','minecraft:obsidian','minecraft:glowstone',
              'minecraft:oak_log','minecraft:birch_log','minecraft:spruce_log','minecraft:jungle_log','minecraft:air','minecraft:air','minecraft:air',
              'minecraft:short_grass', 'minecraft:oak_log[axis=x]', 'minecraft:grass_block[snowy=true]', 'minecraft:oak_stairs[facing=east,half=top,shape=straight,waterlogged=true]'] a;
create temp table rstates as select array_agg(name) a from (select name from ref.block_state order by random() limit 400) q;

-- 1: a random mix over 4 chunks x 4 sections: palette growth 4 -> 5 -> 6 bits, air edits, fluids, leaves, torches
insert into batches select 1, n, (random() * 63)::int, -64 + (random() * 62)::int, (random() * 31)::int, a[1 + (random() * 30)::int] from generate_series(1, 6000) n, names;
-- 2: repeated edits of a few positions (the last edit wins; every change is an event)
insert into batches select 2, n, (random() * 3)::int, -62 + (random() * 3)::int, (random() * 2)::int, a[1 + (random() * 30)::int] from generate_series(1, 3000) n, names;
-- 3: missing sections and chunks, negative coordinates, air in empty sections (no change), a chunk border column
insert into batches select 3, n, -48 + (random() * 47)::int, (random() * 200)::int - 20, -33 + (random() * 30)::int, a[1 + (random() * 30)::int] from generate_series(1, 3000) n, names;
-- 4: one section receives hundreds of distinct states: the palette outgrows 8 bits and becomes the global palette
insert into batches select 4, n, (random() * 15)::int, -64 + (random() * 15)::int, (random() * 15)::int, a[1 + (random() * 399)::int] from generate_series(1, 3000) n, rstates;
-- 5: edits inside a global-palette section (same width, state ids) plus air
insert into batches select 5, n, (random() * 15)::int, -64 + (random() * 15)::int, (random() * 15)::int, case when random() < 0.2 then 'minecraft:air' else a[1 + (random() * 399)::int] end from generate_series(1, 2000) n, rstates;
-- 6a: leaves and torches above the surface (non-collidable blocks do not move MOTION_BLOCKING), 6b: remove them and part of the surface (column tops move down)
insert into batches select 6, n, n % 16, -50, (n / 16) % 8, 'minecraft:oak_leaves' from generate_series(0, 127) n;
insert into batches select 6, 200 + n, n % 16, -49, (n / 16) % 8, 'minecraft:torch' from generate_series(0, 127) n;
insert into batches select 7, n, n % 16, -50, (n / 16) % 8, 'minecraft:air' from generate_series(0, 127) n;
insert into batches select 7, 200 + n, n % 16, -61, (n / 16) % 8, 'minecraft:air' from generate_series(0, 127) n where n % 3 <> 0;
insert into batches select 7, 400 + n, n % 16, -60, (n / 16) % 8, 'minecraft:water' from generate_series(0, 127) n where n % 5 = 0;
-- 8: bare block names (default states) and a column filled and emptied in the same batch
insert into batches select 8, n, 20 + n % 5, -60, 3, (array['minecraft:stone','minecraft:oak_log','minecraft:grass_block','minecraft:oak_stairs','minecraft:air'])[1 + n % 5] from generate_series(0, 49) n;
insert into batches select 8, 100 + n, 30, -61 + n % 3, 5, (array['minecraft:stone','minecraft:air','minecraft:stone','minecraft:air','minecraft:gold_block','minecraft:air'])[1 + n % 6] from generate_series(0, 35) n;
-- 9: eight and nine edits (the threshold between the per-section path and the set-based pass)
insert into batches select 9, n, n, -30, n, 'minecraft:stone' from generate_series(0, 7) n;
insert into batches select 10, n, n, -31, n, 'minecraft:stone' from generate_series(0, 8) n;

create function pg_temp.apply(p_bn int) returns table (c_new int, c_old int) language plpgsql as $$
declare xs int[]; ys int[]; zs int[]; bl text[];
begin
    select array_agg(x order by o), array_agg(y order by o), array_agg(z order by o), array_agg(block order by o) into xs, ys, zs, bl from batches where bn = p_bn;
    c_new := mc.set_blocks('dbcraft:b1', xs, ys, zs, bl);
    c_old := mc_old.set_blocks('dbcraft:b2', xs, ys, zs, bl);
    return next;
end $$;

create function pg_temp.fp(p_dim text) returns table (what text, fp text) language sql stable as $$
  select 'sections', md5(coalesce(string_agg(concat_ws('|', cx, cz, sy, block_count, fluid_count, palette::text, bits, encode(data, 'hex'), biome_palette::text, biome_bits, encode(biome_data, 'hex')), ';' order by cx, cz, sy), ''))
    from mc.chunk_section where dimension = p_dim
  union all
  select 'chunks', md5(coalesce(string_agg(concat_ws('|', cx, cz, version, dirty, hm_dirty, hm_motion_blocking::text, hm_motion_blocking_no_leaves::text, hm_world_surface::text), ';' order by cx, cz), ''))
    from mc.chunk where dimension = p_dim
  union all
  select 'events', md5(coalesce(string_agg(concat_ws('|', x, y, z, old_state, new_state), ';' order by id), ''))
    from mc.block_event where dimension = p_dim $$;

-- apply each batch to both dimensions; after every batch the two must agree completely
do $$
declare b int; r record; fa text; fb text; w text;
begin
    for b in select distinct bn from batches order by 1 loop
        select * into r from pg_temp.apply(b);
        if r.c_new is distinct from r.c_old then raise exception 'FAIL batch %: returned % (new) vs % (old)', b, r.c_new, r.c_old; end if;
        for w in select unnest(array['sections', 'chunks', 'events']) loop
            select fp into fa from pg_temp.fp('dbcraft:b1') where what = w;
            select fp into fb from pg_temp.fp('dbcraft:b2') where what = w;
            if fa is distinct from fb then raise exception 'FAIL batch %: % differ between the new and the old implementation', b, w; end if;
        end loop;
        raise notice 'ok   batch % (% edits, % changed): sections, chunk rows and events identical', b, (select count(*) from batches where bn = b), r.c_new;
    end loop;
end $$;

select t.is_true('the test is not trivial: thousands of events, new sections, all bit widths and a global section were produced',
    (select count(*) > 8000 from mc.block_event where dimension = 'dbcraft:b1')
    and (select count(distinct bits) >= 4 from mc.chunk_section where dimension = 'dbcraft:b1')
    and (select count(*) from mc.chunk_section where dimension = 'dbcraft:b1' and cardinality(palette) = 0) >= 1
    and (select count(*) from mc.chunk where dimension = 'dbcraft:b1') > (select count(*) from mc.chunk where dimension = 'dbcraft:b1' and cx between 0 and 3 and cz between 0 and 1));
select t.is_true('...and column tops were removed and rescanned (the heightmaps changed below the flat surface level 4)',
    (select count(*) > 0 from mc.chunk c, unnest(c.hm_world_surface) h where c.dimension = 'dbcraft:b1' and c.cx = 0 and c.cz = 0 and h <> 4));

-- REGRESSION: a section stores exactly ceil(4096 / entries-per-long) longs.  The first version of mc.edit_section zero-filled twice that many bytes when it turned a
-- single-value or missing section into a palette section by a few edits, which makes the chunk packet unparsable for a client (it reads a fixed number of longs).
create function pg_temp.bad_lengths(p_dim text) returns int language sql stable as $$
  select count(*)::int from mc.chunk_section
   where dimension = p_dim and octet_length(data) <> case when bits = 0 then 0 else ((4096 + (64 / bits) - 1) / (64 / bits)) * 8 end $$;
select t.eq('every section of the new dimension has exactly the number of longs its bit width needs', pg_temp.bad_lengths('dbcraft:b1'), 0);
select t.eq('...and so does every section of the old-path dimension', pg_temp.bad_lengths('dbcraft:b2'), 0);
select mc.set_block('dbcraft:b1', 200, 100, 200, 'minecraft:stone');            -- one edit in a missing section (the few-edits path)
select mc.set_block('dbcraft:b1', 201, 100, 200, 'minecraft:glass');
select t.eq('a section created by single edits has the right length too', pg_temp.bad_lengths('dbcraft:b1'), 0);
select t.eq('...4 bits: 256 longs = 2048 bytes', (select octet_length(data) from mc.chunk_section where dimension = 'dbcraft:b1' and cx = 12 and cz = 12 and sy = 6), 2048);

-- the incremental heightmaps of the set-based pass equal a full recompute
create temp table hm_before as select cx, cz, hm_motion_blocking mb, hm_motion_blocking_no_leaves nl, hm_world_surface ws from mc.chunk where dimension = 'dbcraft:b1';
update mc.chunk set hm_dirty = true where dimension = 'dbcraft:b1';
select count(*) filter (where mc.ensure_chunk_current('dbcraft:b1', cx, cz)) from mc.chunk where dimension = 'dbcraft:b1' and cx between 0 and 3 and cz between 0 and 1;
select t.eq('incremental heightmaps == full recompute (the 8 chunks both batches touched most; all three kinds)',
    (select count(*)::int from mc.chunk c join hm_before b on b.cx = c.cx and b.cz = c.cz
      where c.dimension = 'dbcraft:b1' and c.cx between 0 and 3 and c.cz between 0 and 1
        and (c.hm_motion_blocking <> b.mb or c.hm_motion_blocking_no_leaves <> b.nl or c.hm_world_surface <> b.ws)), 0);

-- the same chunks give the same packets
select t.eq('chunk packets identical (every chunk of both dimensions)',
    (select count(*)::int from mc.chunk a join mc.chunk b on b.dimension = 'dbcraft:b2' and b.cx = a.cx and b.cz = a.cz
      where a.dimension = 'dbcraft:b1' and a.cx between 0 and 3 and a.cz between 0 and 1
        and md5(mc.chunk_packet('dbcraft:b1', a.cx, a.cz)) is distinct from md5(mc.chunk_packet('dbcraft:b2', b.cx, b.cz))), 0);

-- a batch that changes nothing: no events, no version bump, the same return value (0)
create temp table ev_before as select count(*) c from mc.block_event where dimension = 'dbcraft:b1';
create temp table ver_before as select sum(version) s from mc.chunk where dimension = 'dbcraft:b1';
select t.eq('re-applying a finished batch changes nothing (returns 0)',
    (select mc.set_blocks('dbcraft:b1', array_agg(x order by o), array_agg(y order by o), array_agg(z order by o), array_agg(block order by o)) from batches where bn = 10), 0);
select t.eq('...queues no event', (select count(*)::int from mc.block_event where dimension = 'dbcraft:b1'), (select c::int from ev_before));
select t.eq('...and does not bump any version', (select sum(version) from mc.chunk where dimension = 'dbcraft:b1'), (select s from ver_before));

-- errors: nothing of a failing batch survives
create temp table before_fail as select md5(string_agg(concat_ws('|', cx, cz, sy, palette::text, encode(data, 'hex')), ';' order by cx, cz, sy)) m from mc.chunk_section where dimension = 'dbcraft:b1';
select t.raises('an unknown block name in a big batch raises',
    $$select mc.set_blocks('dbcraft:b1', array_fill(1, array[20]), array_fill(-30, array[20]), array_fill(1, array[20]), array_cat(array_fill('minecraft:stone'::text, array[19]), array['minecraft:no_such_block']))$$);
select t.raises('a position outside the world raises',
    $$select mc.set_blocks('dbcraft:b1', array_fill(1, array[20]), array_cat(array_fill(-30, array[19]), array[9000]), array_fill(1, array[20]), array_fill('minecraft:stone'::text, array[20]))$$);
select t.raises('an unknown dimension raises',
    $$select mc.set_blocks('dbcraft:nope', array_fill(1, array[20]), array_fill(-30, array[20]), array_fill(1, array[20]), array_fill('minecraft:stone'::text, array[20]))$$);
select t.raises('arrays of different lengths raise',
    $$select mc.set_blocks('dbcraft:b1', array_fill(1, array[20]), array_fill(-30, array[19]), array_fill(1, array[20]), array_fill('minecraft:stone'::text, array[20]))$$);
select t.eq('...and the failed batches changed nothing',
    (select md5(string_agg(concat_ws('|', cx, cz, sy, palette::text, encode(data, 'hex')), ';' order by cx, cz, sy)) from mc.chunk_section where dimension = 'dbcraft:b1'), (select m from before_fail));
select t.eq('an empty batch is fine (0)', mc.set_blocks('dbcraft:b1', '{}'::int[], '{}'::int[], '{}'::int[], '{}'::text[]), 0);
