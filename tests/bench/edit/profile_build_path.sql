-- The pieces of mc.chunk_packet_build outside the body: ensure_chunk_current, version/cache lookups, framing, the cache write.
\set ON_ERROR_STOP on
set jit = off;
select set_config('perf.base', (200000 + (nextval('public.dbcraft_bench_edit_run') % 100) * 5000)::text, false);
create or replace function pg_temp.ms(t0 timestamptz) returns numeric language sql as $$ select round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3) $$;
do $$
declare t0 timestamptz; n int := 100; b int := current_setting('perf.base')::int; i int; v bigint; body bytea; pkt bytea;
  t_edit numeric; t_ens numeric; t_ver numeric; t_body numeric; t_frame numeric; t_ins numeric; t_comp numeric := 0; t_whole numeric;
begin
  for i in 0 .. n - 1 loop perform mc.generate_flat('minecraft:overworld', b + i, 0); perform mc.chunk_packet('minecraft:overworld', b + i, 0); end loop;
  for i in 0 .. n - 1 loop perform mc.set_block('minecraft:overworld', (b + i) * 16 + 3, -62, 3, 'minecraft:gold_block'); end loop;
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.ensure_chunk_current('minecraft:overworld', b + i, 0); end loop; t_ens := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop select c.version into v from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = b + i and c.cz = 0;
                                                    perform k.packet from mc.chunk_cache k where k.dimension = 'minecraft:overworld' and k.cx = b + i and k.cz = 0 and k.version = v; end loop; t_ver := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop body := mc.chunk_packet_body('minecraft:overworld', b + i, 0); end loop; t_body := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop pkt := proto.frame(mc.chunk_packet_id(), body); end loop; t_frame := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.compression_enabled(); end loop; t_comp := pg_temp.ms(t0);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop
    insert into mc.chunk_cache (dimension, cx, cz, version, packet, packet_z) values ('minecraft:overworld', b + i, 0, 999, pkt, null)
    on conflict (dimension, cx, cz) do update set version = excluded.version, packet = excluded.packet, packet_z = excluded.packet_z; end loop; t_ins := pg_temp.ms(t0);
  raise notice 'B1 ensure_chunk_current (chunk is dirty)    : % ms', round(t_ens / n, 3);
  raise notice 'B2 version + cache lookup                   : % ms', round(t_ver / n, 3);
  raise notice 'B3 chunk_packet_body                        : % ms', round(t_body / n, 3);
  raise notice 'B4 proto.frame(id, body)                    : % ms', round(t_frame / n, 3);
  raise notice 'B5 mc.compression_enabled()                 : % ms', round(t_comp / n, 3);
  raise notice 'B6 chunk_cache upsert (7 KB packet)         : % ms', round(t_ins / n, 3);
  raise notice 'B7 packet size                              : % bytes', octet_length(pkt);
end $$;
