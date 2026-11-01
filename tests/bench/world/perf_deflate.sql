-- Cost and ratio of the SQL DEFLATE encoder (sql/440).   psql -X -f tests/bench/world/perf_deflate.sql   (prints NOTICE lines)
-- Part 1: flat chunks (spliced from the template).  Part 2: the general encoder on real vanilla terrain packets (needs the terrain capture, see
-- tests/bench/world/zlib_baseline.py for the zlib numbers on the same packets).
\set ON_ERROR_STOP on
set jit = off;
\! python3 tools/load_world_ref.py
create or replace function pg_temp.ms(t0 timestamptz) returns numeric language sql as $$ select round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3) $$;

\echo == 1. flat chunks: generation with compression off vs on (n = 300 chunks each, one call per chunk)
update mc.server_property set value = '-1' where key = 'network-compression-threshold';
select set_config('perf.base', (60000 + (extract(epoch from clock_timestamp())::bigint % 1000) * 4)::text, false);
do $$ declare t0 timestamptz; n int := 300; b int := current_setting('perf.base')::int; i int; m numeric;
begin
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.generate_flat('minecraft:overworld', b + i, 0); end loop;
  m := pg_temp.ms(t0); raise notice 'generate_flat, compression off : % ms per chunk', round(m / n, 3);
  perform set_config('perf.on', '1', false);
end $$;
update mc.server_property set value = '256' where key = 'network-compression-threshold';
do $$ declare t0 timestamptz; n int := 300; b int := current_setting('perf.base')::int + 1000; i int; m numeric; raw bigint; z bigint;
begin
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform mc.generate_flat('minecraft:overworld', b + i, 0); end loop;
  m := pg_temp.ms(t0); raise notice 'generate_flat, compression on  : % ms per chunk (packet + compressed frame)', round(m / n, 3);
  select sum(octet_length(packet)), sum(octet_length(packet_z)) into raw, z from mc.chunk_cache where dimension = 'minecraft:overworld' and cx between b and b + n - 1 and cz = 0;
  raise notice 'flat chunk packet: % bytes -> % bytes compressed (%x)', raw / n, z / n, round(raw::numeric / z, 1);
  t0 := clock_timestamp(); for i in 0 .. n - 1 loop perform net.deflate_frame(mc.chunk_packet_id(), mc.packet_body(mc.chunk_packet('minecraft:overworld', b + i, 0))); end loop;
  m := pg_temp.ms(t0); raise notice 'net.deflate_frame on a cached chunk (verified cache hit): % us per call', round(m * 1000 / n, 1);
end $$;

\echo == 2. the general encoder (edited or terrain chunks)
do $$ declare t0 timestamptz; i int; m numeric; payload bytea; z bytea;
begin
  select substring(packet from (select nxt from proto.varint_read(packet, 0)) + 1) into payload from mc.chunk_cache where dimension = 'minecraft:overworld' limit 1;
  t0 := clock_timestamp(); for i in 1 .. 20 loop z := mc.z_frame(payload); end loop;
  m := pg_temp.ms(t0); raise notice 'z_frame of one flat packet (% bytes -> % bytes): % ms each', octet_length(payload), octet_length(z), round(m / 20, 2);
  t0 := clock_timestamp(); for i in 1 .. 20 loop perform mc.adler32(payload); end loop;
  m := pg_temp.ms(t0); raise notice 'adler32 of % bytes: % ms each', octet_length(payload), round(m / 20, 2);
end $$;
create temp table real_pk (cx int, cz int, framed text);
\copy real_pk from program 'python3 tools/import_chunk_capture.py expected'
select (select count(*) from real_pk) > 0 as have_real \gset
\if :have_real
  do $$ declare t0 timestamptz; r record; m numeric; raw bigint := 0; z bigint := 0; n int := 0; payload bytea; zf bytea;
  begin
    t0 := clock_timestamp();
    for r in select * from real_pk loop
      payload := substring(decode(r.framed, 'hex') from (select nxt from proto.varint_read(decode(r.framed, 'hex'), 0)) + 1);
      zf := mc.z_frame(payload); raw := raw + octet_length(payload); z := z + octet_length(zf); n := n + 1;
    end loop;
    m := pg_temp.ms(t0);
    raise notice 'real vanilla terrain: % packets, % bytes -> % bytes (%x): % ms per packet, % MB/s of input', n, raw, z, round(raw::numeric / z, 2), round(m / n, 1), round(raw / 1e6 / (m / 1000), 2);
  end $$;
\endif
update mc.server_property set value = '-1' where key = 'network-compression-threshold';
