-- Lever: evicting cold chunk_cache rows.  Cost of a hit (cached packet) versus a miss (rebuild from the section rows and insert into the cache), 200 random chunks,
-- and what the cache costs in storage.  psql -X -d DB -f tests/bench/scale/lever_evict.sql   (needs scale.keys: any run_scale.py run creates it)
set jit = off;
create temp table ev_keys as select cx, cz from scale.keys where n <= 200;
do $$ declare r record; t0 timestamptz; hit numeric[] := '{}'; miss numeric[] := '{}'; p bytea;
begin
  for r in select * from ev_keys loop
    t0 := clock_timestamp(); p := mc.chunk_packet('minecraft:overworld', r.cx, r.cz);
    hit := hit || (extract(epoch from clock_timestamp() - t0) * 1e6)::numeric;
  end loop;
  delete from mc.chunk_cache c using ev_keys k where c.dimension = 'minecraft:overworld' and c.cx = k.cx and c.cz = k.cz;
  for r in select * from ev_keys loop
    t0 := clock_timestamp(); p := mc.chunk_packet('minecraft:overworld', r.cx, r.cz);
    miss := miss || (extract(epoch from clock_timestamp() - t0) * 1e6)::numeric;
  end loop;
  raise notice 'hit : p50 % us   p99 % us', (select round((percentile_cont(0.5) within group (order by v))::numeric, 1) from unnest(hit) v), (select round((percentile_cont(0.99) within group (order by v))::numeric, 1) from unnest(hit) v);
  raise notice 'miss: p50 % us   p99 % us   (rebuild + cache insert)', (select round((percentile_cont(0.5) within group (order by v))::numeric, 1) from unnest(miss) v), (select round((percentile_cont(0.99) within group (order by v))::numeric, 1) from unnest(miss) v);
end $$;
select pg_size_pretty(pg_total_relation_size('mc.chunk_cache')) as cache_size,
       pg_size_pretty(pg_total_relation_size('mc.chunk') + pg_total_relation_size('mc.chunk_section') + pg_total_relation_size('mc.chunk_light') + pg_total_relation_size('mc.chunk_cache')) as all_chunk_tables,
       round(100.0 * pg_total_relation_size('mc.chunk_cache') / (pg_total_relation_size('mc.chunk') + pg_total_relation_size('mc.chunk_section') + pg_total_relation_size('mc.chunk_light') + pg_total_relation_size('mc.chunk_cache')), 1) as cache_percent;
