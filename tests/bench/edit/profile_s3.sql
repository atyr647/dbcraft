-- Where does the rebuild of a chunk that took 1,000 random edits spend its time?
\set ON_ERROR_STOP on
set jit = off;
select set_config('perf.base', (700000 + (nextval('public.dbcraft_bench_edit_run') % 100) * 5000)::text, false);
create or replace function pg_temp.ms(t0 timestamptz) returns numeric language sql as $$ select round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3) $$;
do $$
declare dim text := 'minecraft:overworld'; t0 timestamptz; n int := 30; b int := current_setting('perf.base')::int; i int; xs int[]; ys int[]; zs int[]; bl text[]; r bytea;
  t_ens numeric; t_body numeric; t_light numeric; t_hm numeric; t_sec numeric; t_wire numeric; t_all numeric; hm smallint[]; c mc.chunk; nl int; nb int;
begin
  perform mc.generate_flat_area(dim, b, 0, b + n - 1, 0);
  for i in 0 .. n - 1 loop perform mc.chunk_packet(dim, b + i, 0); end loop;
  for i in 0 .. n - 1 loop
    select array_agg((b + i) * 16 + (random() * 15)::int), array_agg(-64 + (random() * 62)::int), array_agg((random() * 15)::int),
           array_agg((array['minecraft:stone','minecraft:glass','minecraft:oak_planks','minecraft:sand','minecraft:air'])[1 + (random() * 4)::int])
      into xs, ys, zs, bl from generate_series(1, 1000);
    perform mc.set_blocks(dim, xs, ys, zs, bl);
  end loop;
  -- ensure_chunk_current alone (light recompute, heightmaps maintained incrementally)
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.ensure_chunk_current(dim, b + i, 0); end loop; t_ens := pg_temp.ms(t0);
  select * into c from mc.chunk where dimension = dim and cx = b and cz = 0;
  t0 := clock_timestamp(); for i in 1 .. n loop r := mc.sky_layer(c.hm_world_surface, 16); end loop; t_light := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop r := mc.chunk_packet_body(dim, b + i, 0); end loop; t_body := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.section_wire(s) from mc.chunk_section s where s.dimension = dim and s.cx = b + i and s.cz = 0; end loop; t_sec := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop r := mc.light_wire(dim, b + i, 0); end loop; t_wire := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop r := mc.heightmaps_wire(c, 384); end loop; t_hm := pg_temp.ms(t0);
  select count(*) into nl from mc.chunk_light where dimension = dim and cx = b and cz = 0 and sky_kind = 'data';
  select count(*) into nb from mc.chunk_section where dimension = dim and cx = b and cz = 0;
  raise notice 'T0 chunk has % stored sections, % sky layers with data, heightmap range % .. %', nb, nl, (select min(x) from unnest(c.hm_world_surface) x), (select max(x) from unnest(c.hm_world_surface) x);
  raise notice 'T1 ensure_chunk_current (light recompute)  : % ms', round(t_ens / n, 3);
  raise notice 'T2   one general sky_layer                 : % ms', round(t_light / n, 3);
  raise notice 'T3 chunk_packet_body                       : % ms', round(t_body / n, 3);
  raise notice 'T4   sections (all stored)                 : % ms', round(t_sec / n, 3);
  raise notice 'T5   light_wire                            : % ms', round(t_wire / n, 3);
  raise notice 'T6   heightmaps_wire                       : % ms', round(t_hm / n, 3);
end $$;
