-- Inside mc.chunk_packet_body: where do the ~0.5 ms go?
\set ON_ERROR_STOP on
set jit = off;
select set_config('perf.base', (200000 + (nextval('public.dbcraft_bench_edit_run') % 100) * 5000)::text, false);
create or replace function pg_temp.ms(t0 timestamptz) returns numeric language sql as $$ select round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3) $$;
do $$
declare t0 timestamptz; n int := 200; b int := current_setting('perf.base')::int; i int; r bytea; s mc.chunk_section; pal text[]; cnt int; pb bytea; c mc.chunk;
  t1 numeric; t2 numeric; t3 numeric; t4 numeric; t5 numeric; t6 numeric; t7 numeric; t8 numeric;
begin
  for i in 0 .. n - 1 loop perform mc.generate_flat('minecraft:overworld', b + i, 0); perform mc.chunk_packet('minecraft:overworld', b + i, 0); end loop;
  select * into s from mc.chunk_section where dimension = 'minecraft:overworld' and cx = b and cz = 0;
  select * into c from mc.chunk where dimension = 'minecraft:overworld' and cx = b and cz = 0;
  pal := s.palette;
  t0 := clock_timestamp(); for i in 1 .. n loop
    select count(*), string_agg(proto.varint(bs.state_id), ''::bytea order by p.o) into cnt, pb from unnest(pal) with ordinality p(nm, o) join ref.block_state bs on bs.name = p.nm; end loop; t1 := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 1 .. n loop
    select count(*), string_agg(proto.varint(bb.id), ''::bytea order by p.o) into cnt, pb from unnest(s.biome_palette) with ordinality p(nm, o) join mc.biome bb on bb.name = p.nm; end loop; t2 := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 1 .. n loop r := mc.section_wire(s); end loop; t3 := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 1 .. n loop r := mc.heightmaps_wire3(c.hm_motion_blocking, c.hm_motion_blocking_no_leaves, c.hm_world_surface, 384); end loop; t4 := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 1 .. n loop r := mc.light_wire('minecraft:overworld', b, 0); end loop; t5 := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 1 .. n loop
    select string_agg(case when x.sy is null then '\x00'::bytea else '\x01'::bytea end, ''::bytea order by g) into r
      from generate_series(-4, 19) g left join mc.chunk_section x on x.dimension = 'minecraft:overworld' and x.cx = b and x.cz = 0 and x.sy = g; end loop; t6 := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 1 .. n loop r := mc.chunk_packet_body('minecraft:overworld', b, 0); end loop; t7 := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 1 .. n loop
    select d.min_y, d.height, (select bb.id from mc.biome bb where bb.name = d.default_biome), c2.hm_motion_blocking into cnt, cnt, cnt, pal from mc.chunk c2 join mc.dimension d on d.name = c2.dimension where c2.dimension = 'minecraft:overworld' and c2.cx = b and c2.cz = 0; end loop; t8 := pg_temp.ms(t0);
  raise notice 'Q1 section palette query (%-entry palette)  : % ms', cardinality(pal), round(t1 / n, 4);
  raise notice 'Q2 section biome palette query             : % ms', round(t2 / n, 4);
  raise notice 'Q3 section_wire (whole)                    : % ms', round(t3 / n, 4);
  raise notice 'Q4 heightmaps_wire3                        : % ms', round(t4 / n, 4);
  raise notice 'Q5 light_wire                              : % ms', round(t5 / n, 4);
  raise notice 'Q6 24-section left join scan               : % ms', round(t6 / n, 4);
  raise notice 'Q7 chunk_packet_body (whole)               : % ms', round(t7 / n, 4);
  raise notice 'Q8 chunk + dimension lookup                : % ms', round(t8 / n, 4);
end $$;
