-- The faster chunk rebuild (single-pass wire helpers, bit-mask sky light, light cache key, multi-layer light statement) must give exactly the bytes the original code gave.
-- The original implementations live in schema mc_old (generated from commit 971e8cb by tests/bench/edit/make_old_impl.py).  Two dimensions with the same layers; the same
-- edits go through the same edit functions on both, then one is rebuilt by the new code and the other by the original, and light rows and packets are compared.
\! python3 tools/load_world_ref.py
\ir ../bench/edit/old_impl.sql

------------------------------------------------------------------------------------------------ sky_layer: random heightmaps against the original
create temp table cases (id int, hm smallint[], base int);
select setseed(0.51);
-- uniform surfaces, two levels, smooth terrain, fully random, and the extremes 0 and 384; bases in multiples of 16 (what the light code uses) and arbitrary bases
insert into cases select n, array_fill((random() * 384)::int::smallint, array[256]), (random() * 24)::int * 16 from generate_series(1, 400) n;
insert into cases select 1000 + n, array(select (case when random() < 0.5 then a else b end)::smallint from generate_series(0, 255) g), (random() * 24)::int * 16
  from generate_series(1, 400) n, lateral (select (random() * 384)::int a, (random() * 384)::int b) q;
insert into cases select 2000 + n, array(select (c + (random() * 18)::int + (5 * sin(g / 13.0))::int)::smallint from generate_series(0, 255) g), (random() * 24)::int * 16
  from generate_series(1, 1000) n, lateral (select 4 + (random() * 300)::int c) q;
insert into cases select 4000 + n, array(select (random() * 384)::int::smallint from generate_series(0, 255) g), (random() * 24)::int * 16 from generate_series(1, 400) n;
insert into cases select 5000 + n, array(select (case when random() < 0.5 then 0 else 384 end)::smallint from generate_series(0, 255) g), (random() * 24)::int * 16 from generate_series(1, 200) n;
insert into cases select 6000 + n, array(select (random() * 400)::int::smallint from generate_series(0, 255) g), (random() * 400)::int from generate_series(1, 400) n;
select t.eq('sky_layer: 2,800 random heightmaps give the original bytes', (select count(*)::int from cases where mc.sky_layer(hm, base) is distinct from mc_old.sky_layer(hm, base)), 0);
select t.eq('...every layer is 2,048 bytes', (select count(*)::int from cases where octet_length(mc.sky_layer(hm, base)) <> 2048), 0);

------------------------------------------------------------------------------------------------ whole chunks: light rows and packets after edits
insert into mc.dimension (name) values ('dbcraft:r1'), ('dbcraft:r2');
insert into mc.flat_layer (dimension, y, block)
select d, y, b from (values ('dbcraft:r1'), ('dbcraft:r2')) dd(d),
     (values (-64, 'minecraft:bedrock'), (-63, 'minecraft:dirt'), (-62, 'minecraft:dirt'), (-61, 'minecraft:grass_block')) l(y, b);
select mc.generate_flat_area('dbcraft:r1', 0, 0, 3, 1);
select mc.generate_flat_area('dbcraft:r2', 0, 0, 3, 1);

create function pg_temp.light_fp(p_dim text) returns table (cx int, cz int, fp text) language sql stable as $$
  select cx, cz, md5(string_agg(concat_ws('|', idx, sky_kind, encode(sky, 'hex'), block_kind, encode(block, 'hex')), ';' order by idx))
    from mc.chunk_light where dimension = p_dim group by cx, cz $$;

-- rebuild every chunk of r1 with the new code and of r2 with the original, then compare light rows and the packet bodies
create function pg_temp.compare_all(stage text) returns void language plpgsql as $$
declare c record; bad_light int; bad_body int; bad_wire int;
begin
    for c in select cx, cz from mc.chunk where dimension = 'dbcraft:r1' and cx between 0 and 3 and cz between 0 and 1 loop
        perform mc.ensure_chunk_current('dbcraft:r1', c.cx, c.cz);
        perform mc_old.ensure_chunk_current('dbcraft:r2', c.cx, c.cz);
    end loop;
    select count(*) into bad_light from pg_temp.light_fp('dbcraft:r1') a full join pg_temp.light_fp('dbcraft:r2') b using (cx, cz) where a.fp is distinct from b.fp;
    select count(*) into bad_body from mc.chunk a join mc.chunk b on b.dimension = 'dbcraft:r2' and b.cx = a.cx and b.cz = a.cz
     where a.dimension = 'dbcraft:r1' and a.cx between 0 and 3 and a.cz between 0 and 1
       and mc.chunk_packet_body('dbcraft:r1', a.cx, a.cz) is distinct from mc_old.chunk_packet_body('dbcraft:r2', b.cx, b.cz);
    -- the helpers one by one, on the stored rows of every chunk
    select count(*) into bad_wire from mc.chunk_section a join mc.chunk_section b on b.dimension = 'dbcraft:r2' and (b.cx, b.cz, b.sy) = (a.cx, a.cz, a.sy)
     where a.dimension = 'dbcraft:r1' and mc.section_wire(a) is distinct from mc_old.section_wire(b);
    if bad_light > 0 then raise exception 'FAIL %: light rows differ in % chunks', stage, bad_light; end if;
    if bad_body > 0 then raise exception 'FAIL %: packet bodies differ in % chunks', stage, bad_body; end if;
    if bad_wire > 0 then raise exception 'FAIL %: section wire differs in % sections', stage, bad_wire; end if;
    raise notice 'ok   %: light rows, packet bodies and section wire identical in all 8 chunks', stage;
end $$;

select pg_temp.compare_all('fresh flat chunks');

-- stage a: edits below the surface (the light inputs do not change: the new code skips the rebuild; the result must still be the original's)
select mc.set_blocks(d, array_agg(n % 64), array_agg(-63 + (n % 2)), array_agg((n / 64) % 32), array_agg(case when n % 3 = 0 then 'minecraft:gold_block' else 'minecraft:stone' end))
  from generate_series(0, 199) n, (values ('dbcraft:r1'), ('dbcraft:r2')) v(d) group by d;
select pg_temp.compare_all('stage a: edits below the surface');

-- stage b: single edits above the surface raise single columns (one partial layer)
select mc.set_block(d, 5 + n * 3, -55 + n, 5, 'minecraft:stone') from generate_series(0, 9) n, (values ('dbcraft:r1'), ('dbcraft:r2')) v(d);
select pg_temp.compare_all('stage b: a few raised columns');

-- stage c: a thousand random edits per dimension, including air (column tops move down), leaves and torches
create temp table c_edits as
select n, (random() * 63)::int x, -64 + (random() * 62)::int y, (random() * 31)::int z,
       (array['minecraft:stone','minecraft:glass','minecraft:oak_planks','minecraft:sand','minecraft:air','minecraft:air','minecraft:oak_leaves','minecraft:torch','minecraft:water','minecraft:oak_log'])[1 + (random() * 9)::int] b
  from generate_series(1, 3000) n;
select mc.set_blocks(d, array_agg(x order by n), array_agg(y order by n), array_agg(z order by n), array_agg(b order by n)) from c_edits, (values ('dbcraft:r1'), ('dbcraft:r2')) v(d) group by d;
select pg_temp.compare_all('stage c: 3,000 random edits (tops raised and lowered)');

-- stage d: remove everything above the flat surface again, then fill and empty a high section (the highest non-empty section changes)
select mc.set_blocks(d, array_agg(x order by n), array_agg(y order by n), array_agg(z order by n), array_agg('minecraft:air'::text order by n)) from c_edits, (values ('dbcraft:r1'), ('dbcraft:r2')) v(d) where y > -61 group by d;
select pg_temp.compare_all('stage d: everything above the surface removed');
select mc.fill(d, 0, 100, 0, 15, 115, 15, 'minecraft:stone') from (values ('dbcraft:r1'), ('dbcraft:r2')) v(d);
select pg_temp.compare_all('stage e: a high section filled (light layers up to the top)');
select mc.fill(d, 0, 100, 0, 15, 115, 15, 'minecraft:air') from (values ('dbcraft:r1'), ('dbcraft:r2')) v(d);
select pg_temp.compare_all('stage f: ... and emptied again');

-- stage g: block entities and a section that outgrows the palette (global palette wire format)
insert into mc.block_entity (dimension, cx, cz, x, y, z, type, nbt) select d, 0, 0, 3, -60, 3, 'minecraft:chest', '\x00' from (values ('dbcraft:r1'), ('dbcraft:r2')) v(d);
create temp table big_states as select array_agg(name) a from (select name from ref.block_state order by random() limit 300) q;
select mc.set_blocks(d, array_agg(n % 16 order by n), array_agg(-64 + (n / 256) % 16 order by n), array_agg((n / 16) % 16 order by n), array_agg(a[1 + n % 299] order by n))
  from generate_series(0, 2999) n, big_states, (values ('dbcraft:r1'), ('dbcraft:r2')) v(d) group by d;
select t.is_true('...the section became a global-palette section', (select count(*) >= 1 from mc.chunk_section where dimension = 'dbcraft:r1' and cardinality(palette) = 0));
select pg_temp.compare_all('stage g: block entity + global-palette section');

------------------------------------------------------------------------------------------------ the light cache key
select mc.ensure_chunk_current('dbcraft:r1', 1, 1);                                                  -- current
create temp table light_x as select idx, xmin::text::bigint as xm from mc.chunk_light where dimension = 'dbcraft:r1' and cx = 1 and cz = 1;
select mc.compute_light('dbcraft:r1', 1, 1);
select t.eq('compute_light with a matching key rewrites no row',
    (select count(*)::int from mc.chunk_light l join light_x x on x.idx = l.idx where l.dimension = 'dbcraft:r1' and l.cx = 1 and l.cz = 1 and l.xmin::text::bigint <> x.xm), 0);
select mc.set_block('dbcraft:r1', 16 + 4, -63, 16 + 4, 'minecraft:emerald_block');                  -- below the surface: heightmap and top section unchanged
select mc.ensure_chunk_current('dbcraft:r1', 1, 1);
select t.eq('an edit below the surface leaves the light rows untouched',
    (select count(*)::int from mc.chunk_light l join light_x x on x.idx = l.idx where l.dimension = 'dbcraft:r1' and l.cx = 1 and l.cz = 1 and l.xmin::text::bigint <> x.xm), 0);
select t.is_true('...and the chunk is clean again', (select not dirty from mc.chunk where dimension = 'dbcraft:r1' and cx = 1 and cz = 1));
delete from mc.chunk_light where dimension = 'dbcraft:r1' and cx = 1 and cz = 1 and idx = 2;
update mc.chunk set dirty = true where dimension = 'dbcraft:r1' and cx = 1 and cz = 1;
select mc.ensure_chunk_current('dbcraft:r1', 1, 1);
select t.eq('a deleted light row is rebuilt even though the key matches (row count check)',
    (select count(*)::int from mc.chunk_light where dimension = 'dbcraft:r1' and cx = 1 and cz = 1), (select count(*)::int from mc.chunk_light where dimension = 'dbcraft:r2' and cx = 1 and cz = 1));
select mc.compute_light('dbcraft:r1', 2, 0, true);
select mc_old.compute_light('dbcraft:r2', 2, 0, true);
select t.eq('compute_light(p_sky0_as_data => true) gives the original rows', (select fp from pg_temp.light_fp('dbcraft:r1') where cx = 2 and cz = 0), (select fp from pg_temp.light_fp('dbcraft:r2') where cx = 2 and cz = 0));
select t.is_true('...and leaves no cache key (the next normal rebuild must restore layer 0 as an empty bit)', (select light_ws is null and light_top is null from mc.chunk where dimension = 'dbcraft:r1' and cx = 2 and cz = 0));
select mc.compute_light('dbcraft:r1', 2, 0);
select mc_old.compute_light('dbcraft:r2', 2, 0);
select t.eq('...a later normal call restores the plain form', (select fp from pg_temp.light_fp('dbcraft:r1') where cx = 2 and cz = 0), (select fp from pg_temp.light_fp('dbcraft:r2') where cx = 2 and cz = 0));
