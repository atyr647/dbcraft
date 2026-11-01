-- Where does the time of "edit one block, then build the chunk packet" go?   psql -X -d DB -f tests/bench/edit/profile_rebuild.sql
\set ON_ERROR_STOP on
set jit = off;
create sequence if not exists public.dbcraft_bench_edit_run;
select set_config('perf.base', (200000 + (nextval('public.dbcraft_bench_edit_run') % 100) * 5000)::text, false);
create or replace function pg_temp.ms(t0 timestamptz) returns numeric language sql as $$ select round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3) $$;
do $$
declare t0 timestamptz; n int := 100; b int := current_setting('perf.base')::int; i int;
  tl numeric := 0; tb numeric := 0; th numeric := 0; tlw numeric := 0; tsw numeric := 0; te numeric := 0; tf numeric := 0; tall numeric := 0; tedit numeric := 0;
  d mc.dimension%rowtype; c mc.chunk%rowtype;
begin
  for i in 0 .. n - 1 loop perform mc.generate_flat('minecraft:overworld', b + i, 0); perform mc.chunk_packet('minecraft:overworld', b + i, 0); end loop;
  select * into d from mc.dimension where name = 'minecraft:overworld';
  -- A: whole thing: one edit below the surface, then the packet
  t0 := clock_timestamp();
  for i in 0 .. n - 1 loop perform mc.set_block('minecraft:overworld', (b + i) * 16 + 3, -62, 3, 'minecraft:gold_block'); end loop;
  tedit := pg_temp.ms(t0);
  t0 := clock_timestamp();
  for i in 0 .. n - 1 loop perform mc.chunk_packet('minecraft:overworld', b + i, 0); end loop;
  tall := pg_temp.ms(t0);
  raise notice 'P0 set_block alone                           : % ms per edit', round(tedit / n, 3);
  raise notice 'P1 chunk_packet after one edit (whole)       : % ms per rebuild', round(tall / n, 3);
  -- B: the components, each on its own, chunks in the same state (current, not dirty)
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.compute_light('minecraft:overworld', b + i, 0); end loop; tl := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.chunk_packet_body('minecraft:overworld', b + i, 0); end loop; tb := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop select * into c from mc.chunk where dimension = 'minecraft:overworld' and cx = b + i and cz = 0; perform mc.heightmaps_wire(c, d.height); end loop; th := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.light_wire('minecraft:overworld', b + i, 0); end loop; tlw := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.section_wire(s) from mc.chunk_section s where s.dimension = 'minecraft:overworld' and s.cx = b + i and s.cz = 0; end loop; tsw := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.block_entities_wire('minecraft:overworld', b + i, 0); end loop; te := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.sky_layer(array_fill(4::smallint, array[256]), 0 + i * 0); end loop; tf := pg_temp.ms(t0);
  raise notice 'P2 compute_light (3 layers)                  : % ms', round(tl / n, 3);
  raise notice 'P3 chunk_packet_body (all of it)             : % ms', round(tb / n, 3);
  raise notice 'P4   heightmaps_wire                         : % ms', round(th / n, 3);
  raise notice 'P5   light_wire                              : % ms', round(tlw / n, 3);
  raise notice 'P6   section_wire (the one stored section)   : % ms', round(tsw / n, 3);
  raise notice 'P7   block_entities_wire                     : % ms', round(te / n, 3);
  raise notice 'P8 sky_layer (one partial layer)             : % ms', round(tf / n, 3);
end $$;
