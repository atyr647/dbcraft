set jit = off;
create schema if not exists bench;
create or replace function bench.cpu_ms() returns numeric language sql volatile as $$
  select (split_part(pg_read_file('/proc/self/schedstat'), ' ', 1))::numeric / 1000000.0 $$;
delete from mc.chunk_cache;
do $$ declare t0 numeric; r record; n int := 0;
begin
  t0 := bench.cpu_ms();
  for r in select dimension, cx, cz from mc.chunk order by cx, cz limit 300 loop perform mc.chunk_packet(r.dimension, r.cx, r.cz); n := n + 1; end loop;
  raise notice 'cold build: % chunks, % ms CPU per chunk', n, round((bench.cpu_ms() - t0) / n, 2);
end $$;
