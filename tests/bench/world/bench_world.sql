-- World benchmarks.  Run after migrations + reference data:
--   DBCRAFT_PGPORT=54329 ... psql -X -f tests/bench/world/bench_world.sql        (from the repo root; prints NOTICE lines)
-- Uses its own dimension ('dbcraft:bench') and, when the capture exists, the real-terrain chunks (see tests/sql/250_world_terrain_oracle.sql).
-- Numbers depend on the machine; compare them with the 50 ms tick budget, not with each other across machines.
\set ON_ERROR_STOP on
set jit = off;
\! python3 tools/load_world_ref.py

create function pg_temp.timeit(label text, n int, stmt text) returns void language plpgsql as $$
declare t0 timestamptz; i int; ms numeric;
begin
    t0 := clock_timestamp();
    for i in 1 .. n loop execute stmt; end loop;
    ms := extract(epoch from clock_timestamp() - t0) * 1000;
    raise notice '% | % runs | % ms total | % us each', rpad(label, 62), n, round(ms, 1), round(ms * 1000 / n, 1);
end $$;

insert into mc.dimension (name) values ('dbcraft:bench') on conflict do nothing;
insert into mc.flat_layer (dimension, y, block) values
    ('dbcraft:bench', -64, 'minecraft:bedrock'), ('dbcraft:bench', -63, 'minecraft:dirt'), ('dbcraft:bench', -62, 'minecraft:dirt'), ('dbcraft:bench', -61, 'minecraft:grass_block')
on conflict do nothing;
delete from mc.chunk where dimension = 'dbcraft:bench';

\echo
\echo == generation
do $$ declare t0 timestamptz := clock_timestamp(); n int; begin
    n := mc.generate_flat_area('dbcraft:bench', 0, 0, 7, 7);
    raise notice 'generate_flat_area 8x8 chunks (heightmaps + light included) | % chunks | % ms total | % ms per chunk', n,
        round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1), round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / n, 2);
end $$;

\echo
\echo == single edits (one section read + write each, edits spread over an 8x8 chunk flat area, y -64..-45)
select pg_temp.timeit('set_block, random position, 4 block types', 20000,
    $q$select mc.set_block('dbcraft:bench', (random()*127)::int, -64 + (random()*19)::int, (random()*127)::int, (array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand'])[1+(random()*3)::int])$q$);
select pg_temp.timeit('get_block, random position', 20000, $q$select mc.get_block('dbcraft:bench', (random()*127)::int, -64 + (random()*19)::int, (random()*127)::int)$q$);

\echo
\echo == batched edits: mc.set_blocks(10000 edits) at different spreads
create function pg_temp.batch(label text, n int, xspan int, yspan int, zspan int, x0 int default 0, y0 int default -64, z0 int default 0) returns void language plpgsql as $$
declare xs int[]; ys int[]; zs int[]; bl text[]; t0 timestamptz; ch int; ms numeric; secs int;
begin
    select array_agg(x0 + (random() * (xspan - 1))::int), array_agg(y0 + (random() * (yspan - 1))::int), array_agg(z0 + (random() * (zspan - 1))::int),
           array_agg((array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand','minecraft:glass','minecraft:oak_planks'])[1 + (random() * 5)::int])
      into xs, ys, zs, bl from generate_series(1, n);
    secs := (select count(distinct (x >> 4, y >> 4, z >> 4)) from unnest(xs, ys, zs) t(x, y, z));
    t0 := clock_timestamp();
    ch := mc.set_blocks('dbcraft:bench', xs, ys, zs, bl);
    ms := extract(epoch from clock_timestamp() - t0) * 1000;
    raise notice '% | % edits in % sections | % changed | % ms (% ms per section)', rpad(label, 46), n, secs, ch, round(ms, 1), round(ms / secs, 2);
end $$;
select pg_temp.batch('10k edits inside ONE section (a building site)', 10000, 16, 16, 16, 0, -64, 0);
select pg_temp.batch('10k edits in 4 sections (2x2 chunks, one layer)', 10000, 32, 16, 32, 0, -64, 0);
select pg_temp.batch('10k edits in 16 sections', 10000, 64, 16, 64, 0, -64, 0);
select pg_temp.batch('10k edits in 64 sections (whole flat area, one layer)', 10000, 128, 16, 128, 0, -64, 0);
select pg_temp.batch('1k edits in 64 sections', 1000, 128, 16, 128, 0, -64, 0);
select pg_temp.batch('10k edits scattered over 448 sections', 10000, 128, 112, 128, 0, -64, 0);
select pg_temp.batch('100 edits in 100 sections (sparse)', 100, 128, 112, 128, 0, -64, 0);

\echo
\echo == fill
select pg_temp.timeit('fill one whole section (single-value replace)', 200, $q$select mc.fill('dbcraft:bench', 0, 0, 0, 15, 15, 15, 'minecraft:stone')$q$);
select pg_temp.timeit('fill 64x64x64 (64 whole sections)', 20, $q$select mc.fill('dbcraft:bench', 0, 16, 0, 63, 79, 63, 'minecraft:glass')$q$);
select pg_temp.timeit('fill a 16x1x16 floor (partial section, 256 blocks)', 200, $q$select mc.fill('dbcraft:bench', 0, 100, 0, 15, 100, 15, 'minecraft:oak_planks')$q$);
select pg_temp.timeit('fill 40x40x40 not aligned (partial sections at the edges)', 20, $q$select mc.fill('dbcraft:bench', 3, 130, 5, 42, 169, 44, 'minecraft:gravel')$q$);

\echo
\echo == chunk packets (pristine flat chunks, a separate area so the edit benchmarks above do not skew them)
select mc.generate_flat_area('dbcraft:bench', 20, 0, 27, 0);
do $$ declare t0 timestamptz; i int; ms numeric; begin
    delete from mc.chunk_cache where dimension = 'dbcraft:bench' and cx between 20 and 27;
    t0 := clock_timestamp();
    for i in 20 .. 27 loop perform mc.chunk_packet('dbcraft:bench', i, 0); end loop;
    ms := extract(epoch from clock_timestamp() - t0) * 1000;
    raise notice 'chunk_packet COLD (derived data current, no cache row)                | 8 runs | % ms total | % us each', round(ms, 1), round(ms * 1000 / 8, 1);
end $$;
select pg_temp.timeit('chunk_packet CACHED (cache hit)', 2000, $q$select mc.chunk_packet('dbcraft:bench', 21, 0)$q$);
select pg_temp.timeit('one edit + chunk_packet (dirty: recompute heightmaps+light, re-encode)', 200,
    $q$select mc.set_block('dbcraft:bench', 21 * 16 + 1, -60, 3, (array['minecraft:stone','minecraft:air'])[1 + (random())::int]); select mc.chunk_packet('dbcraft:bench', 21, 0)$q$);
select pg_temp.timeit('chunk_packet_body only (flat chunk, no cache, no recompute)', 500, $q$select mc.chunk_packet_body('dbcraft:bench', 22, 0)$q$);
select pg_temp.timeit('compute_heightmaps (flat chunk)', 500, $q$select * from mc.compute_heightmaps('dbcraft:bench', 22, 0)$q$);
select pg_temp.timeit('compute_light (flat chunk)', 200, $q$select mc.compute_light('dbcraft:bench', 22, 0)$q$);
select pg_temp.timeit('generate_flat one chunk (replace)', 50, $q$select mc.generate_flat('dbcraft:bench', 23, 0, true)$q$);
select pg_temp.timeit('framed packet size is irrelevant to cost; bytes of a cached flat packet', 1, $q$select octet_length(mc.chunk_packet('dbcraft:bench', 21, 0))$q$);

\echo == real terrain chunks (needs the capture)
create temp table expected (cx int, cz int, framed text);
\copy expected from program 'python3 tools/import_chunk_capture.py expected'
select count(*) > 0 as have_terrain from expected \gset
\if :have_terrain
  insert into mc.dimension (name) values ('dbcraft:terrain') on conflict do nothing;
  delete from mc.chunk where dimension = 'dbcraft:terrain';
  \copy mc.chunk (dimension, cx, cz, hm_motion_blocking, hm_motion_blocking_no_leaves, hm_world_surface, dirty) from program 'python3 tools/import_chunk_capture.py chunks'
  \copy mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data) from program 'python3 tools/import_chunk_capture.py sections'
  \copy mc.chunk_light (dimension, cx, cz, idx, sky_kind, sky, block_kind, block) from program 'python3 tools/import_chunk_capture.py light'
  \copy mc.block_entity (dimension, cx, cz, x, y, z, type, nbt) from program 'python3 tools/import_chunk_capture.py entities'
  select min(cx) as tmin_cx, min(cz) as tmin_cz from mc.chunk where dimension = 'dbcraft:terrain' \gset
  do $d$ declare t0 timestamptz; r record; n int := 0; ms numeric; begin
      t0 := clock_timestamp();
      for r in select cx, cz from mc.chunk where dimension = 'dbcraft:terrain' loop perform mc.chunk_packet_body('dbcraft:terrain', r.cx, r.cz); n := n + 1; end loop;
      ms := extract(epoch from clock_timestamp() - t0) * 1000;
      raise notice 'chunk_packet_body, real terrain chunk (24 sections, ~11 palette)       | % runs | % ms total | % us each', n, round(ms, 1), round(ms * 1000 / n, 1);
      t0 := clock_timestamp(); n := 0;
      for r in select cx, cz from mc.chunk where dimension = 'dbcraft:terrain' loop perform * from mc.compute_heightmaps('dbcraft:terrain', r.cx, r.cz); n := n + 1; end loop;
      ms := extract(epoch from clock_timestamp() - t0) * 1000;
      raise notice 'compute_heightmaps, real terrain chunk                                 | % runs | % ms total | % us each', n, round(ms, 1), round(ms * 1000 / n, 1);
      t0 := clock_timestamp(); n := 0;
      for r in select cx, cz from mc.chunk where dimension = 'dbcraft:terrain' loop perform mc.compute_light('dbcraft:terrain', r.cx, r.cz); n := n + 1; end loop;
      ms := extract(epoch from clock_timestamp() - t0) * 1000;
      raise notice 'compute_light, real terrain chunk                                      | % runs | % ms total | % us each', n, round(ms, 1), round(ms * 1000 / n, 1);
  end $d$;
  select pg_temp.timeit('get_block in real terrain', 20000, format($q$select mc.get_block('dbcraft:terrain', %s * 16 + (random() * 63)::int, -64 + (random() * 100)::int, %s * 16 + (random() * 63)::int)$q$, :tmin_cx, :tmin_cz));
  \echo
  \echo == storage (real terrain)
  select 'sections' as what, count(*) as n, round(avg(pg_column_size(s.*))) as avg_row_bytes, max(pg_column_size(s.*)) as max_row_bytes from mc.chunk_section s where dimension = 'dbcraft:terrain'
  union all select 'palette sections (bits > 0)', count(*), round(avg(pg_column_size(s.*))), max(pg_column_size(s.*)) from mc.chunk_section s where dimension = 'dbcraft:terrain' and bits > 0
  union all select 'single-value sections', count(*), round(avg(pg_column_size(s.*))), max(pg_column_size(s.*)) from mc.chunk_section s where dimension = 'dbcraft:terrain' and bits = 0;
  select 'bytes per terrain chunk (all section rows)' as what, round(sum(pg_column_size(s.*)) / count(distinct (cx, cz))) as bytes from mc.chunk_section s where dimension = 'dbcraft:terrain';
\else
  \echo (skipped: no terrain capture)
\endif

\echo
\echo == storage (flat world)
select 'flat world: bytes per chunk (section rows)' as what, round(sum(pg_column_size(s.*)) / count(distinct (cx, cz))) as bytes from mc.chunk_section s where dimension = 'dbcraft:bench' and block_count > 0 and sy = -4;
select 'chunk_section toast size (sections moved out of line)', pg_size_pretty(pg_relation_size((select reltoastrelid from pg_class where oid = 'mc.chunk_section'::regclass)));
select 'rows in mc.chunk_section / mc.chunk / mc.chunk_light', (select count(*) from mc.chunk_section), (select count(*) from mc.chunk), (select count(*) from mc.chunk_light);
select 'chunk_section heap + toast size', pg_size_pretty(pg_total_relation_size('mc.chunk_section'));

\echo
\echo == the readable view (the cost of "WHERE x = .. AND y = .. AND z = .." on mc.blocks)
select 'sections in the database', count(*) from mc.chunk_section;
select pg_temp.timeit('mc.block_at (point read)', 5000, $q$select * from mc.block_at('dbcraft:bench', 70, -61, 70)$q$);
select pg_temp.timeit('mc.blocks_in a 16x16x16 box (touches one section)', 500, $q$select count(*) from mc.blocks_in('dbcraft:bench', 0, -64, 0, 15, -49, 15)$q$);
select pg_temp.timeit('mc.blocks WHERE x,y,z = one block (scans EVERY section)', 3, $q$select * from mc.blocks where dimension = 'dbcraft:bench' and x = 70 and y = -61 and z = 70$q$);
select pg_temp.timeit('UPDATE mc.blocks ... WHERE x,y,z (scans every section, then edits)', 3, $q$update mc.blocks set block = 'minecraft:stone' where dimension = 'dbcraft:bench' and x = 70 and y = -61 and z = 70$q$);
