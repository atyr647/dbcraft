-- Lever: BRIN on chunk coordinates for region scans, compared with the btree primary key.  Needs lever.c_plain (tests/bench/scale/lever_partition.py), filled in (cx, cz) order,
-- i.e. the best case for BRIN; a scattered insertion order makes BRIN useless (its summaries then cover every range).
set jit = off;
drop index if exists lever.c_plain_brin;
create index c_plain_brin on lever.c_plain using brin (cx, cz) with (pages_per_range = 4);
select pg_size_pretty(pg_relation_size('lever.c_plain_brin')) as brin_size, pg_size_pretty(pg_relation_size('lever.c_plain_pkey')) as btree_size;
create function pg_temp.ms(q text, n int default 7) returns text language plpgsql as $$
declare t0 timestamptz; i int; r numeric[] := '{}'; cnt bigint;
begin
  for i in 1 .. n loop t0 := clock_timestamp(); execute q into cnt; r := r || (extract(epoch from clock_timestamp() - t0) * 1000)::numeric; end loop;
  return (select round((percentile_cont(0.5) within group (order by v))::numeric, 3) from unnest(r) v) || ' ms (median of ' || n || '), rows ' || cnt;
end $$;
\echo == 16 x 16 chunk box: btree primary key (index-only scan), then BRIN (bitmap scan)
select pg_temp.ms($q$select count(*) from lever.c_plain where dimension = 'minecraft:overworld' and cx between 0 and 15 and cz between 0 and 15$q$) as btree;
set enable_indexscan = off; set enable_indexonlyscan = off; set enable_bitmapscan = on; set enable_seqscan = off;
select pg_temp.ms($q$select count(*) from lever.c_plain where cx between 0 and 15 and cz between 0 and 15$q$) as brin;
explain (analyze, costs off, timing off) select count(*) from lever.c_plain where cx between 0 and 15 and cz between 0 and 15;
reset enable_indexscan; reset enable_indexonlyscan; reset enable_bitmapscan; reset enable_seqscan;
\echo == 4 x 4 chunk box
select pg_temp.ms($q$select count(*) from lever.c_plain where dimension = 'minecraft:overworld' and cx between 0 and 3 and cz between 0 and 3$q$) as btree;
set enable_indexscan = off; set enable_indexonlyscan = off; set enable_bitmapscan = on; set enable_seqscan = off;
select pg_temp.ms($q$select count(*) from lever.c_plain where cx between 0 and 3 and cz between 0 and 3$q$) as brin;
reset enable_indexscan; reset enable_indexonlyscan; reset enable_bitmapscan; reset enable_seqscan;
\echo == 1 chunk (the lookup every operation does)
select pg_temp.ms($q$select count(*) from lever.c_plain where dimension = 'minecraft:overworld' and cx = 7 and cz = 9$q$, 50) as btree;
