-- After the crash: is the (unlogged) cache empty, and what do the first joins cost while it refills?  Needs scale.lkeys (lever_toast.py).
set jit = off;
select count(*) as cache_rows_after_crash from mc.chunk_cache;
do $$ declare k record; t0 timestamptz; cnt int; ms numeric;
begin
  for k in select * from scale.lkeys where n <= 3 order by n loop
    t0 := clock_timestamp(); select count(*) into cnt from net.hook_chunks(-1, k.cx, k.cz, 9);
    ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);
    raise notice 'first join at (%,%) after the crash: % chunks, % ms', k.cx, k.cz, cnt, ms;
    t0 := clock_timestamp(); select count(*) into cnt from net.hook_chunks(-1, k.cx, k.cz, 9);
    raise notice '   the same join again (cache refilled): % chunks, % ms', cnt, round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);
  end loop;
end $$;
select count(*) as cache_rows_after_refill from mc.chunk_cache;
