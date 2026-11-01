-- Variant 9: storage of mc.chunk_cache.packet.  Copies of the cache table with STORAGE default (EXTENDED: pglz-compressed, out of line when large), EXTERNAL (out of line,
-- never compressed) and MAIN (compressed, kept inline when it fits), then: size, cost of reading the cached packets of a tick's chunk streaming (575 random chunks, forced
-- detoast) and of a join-sized fan-out (529 chunks to each of 20 connections, concatenated).  CPU time is the backend's on-CPU time (bbench.sched), median of 15 runs.
-- usage: psql -f tests/bench/batch/cache_storage.sql     (in the warm benchmark database)
create schema if not exists bstore;
drop table if exists bstore.cc_default, bstore.cc_external, bstore.cc_main;
create table bstore.cc_default  (like mc.chunk_cache including all);
create table bstore.cc_external (like mc.chunk_cache including all);
create table bstore.cc_main     (like mc.chunk_cache including all);
alter table bstore.cc_default  alter column packet set storage extended;
alter table bstore.cc_external alter column packet set storage external;
alter table bstore.cc_main     alter column packet set storage main;
-- `|| ''` makes the value a fresh uncompressed datum, so each table's own storage setting decides how it is stored
insert into bstore.cc_default  select dimension, cx, cz, version, packet || ''::bytea from mc.chunk_cache;
insert into bstore.cc_external select dimension, cx, cz, version, packet || ''::bytea from mc.chunk_cache;
insert into bstore.cc_main     select dimension, cx, cz, version, packet || ''::bytea from mc.chunk_cache;
vacuum analyze bstore.cc_default; vacuum analyze bstore.cc_external; vacuum analyze bstore.cc_main;

\echo -- size
select 'default' as storage, count(*) as rows, round(avg(octet_length(packet))) as avg_raw_bytes, round(avg(pg_column_size(packet))) as avg_stored_bytes,
       pg_size_pretty(pg_relation_size('bstore.cc_default')) as heap, pg_size_pretty(pg_total_relation_size('bstore.cc_default')) as total_with_toast_and_index from bstore.cc_default
union all select 'external', count(*), round(avg(octet_length(packet))), round(avg(pg_column_size(packet))), pg_size_pretty(pg_relation_size('bstore.cc_external')), pg_size_pretty(pg_total_relation_size('bstore.cc_external')) from bstore.cc_external
union all select 'main', count(*), round(avg(octet_length(packet))), round(avg(pg_column_size(packet))), pg_size_pretty(pg_relation_size('bstore.cc_main')), pg_size_pretty(pg_total_relation_size('bstore.cc_main')) from bstore.cc_main;

create or replace function bstore.run(p_tbl text, p_reads int, p_reps int) returns table(what text, cpu_ms float8) language plpgsql as $$
declare i int; s0 bigint[]; s1 bigint[]; x bigint;
begin
    for i in 1..p_reps loop
        -- 575 pseudo-random chunks, each packet fully detoasted
        s0 := bbench.sched();
        execute format('select sum(get_byte(c.packet, 100)) from %s c join (select cx, cz from (select (hashint4(g + %s) & 127) - 14 as cx, ((hashint4(g * 7 + %s)) & 127) - 14 as cz from generate_series(1, %s) g) q group by cx, cz) w using (cx, cz)', p_tbl, i, i, p_reads) into x;
        s1 := bbench.sched(); what := 'tick: ' || p_reads || ' random cached packets'; cpu_ms := (s1[1] - s0[1]) / 1e6; return next;
        -- join-sized fan-out: 20 connections x 529 chunks, concatenated per connection
        s0 := bbench.sched();
        execute format('select sum(length(b)) from (select conn, string_agg(c.packet, ''''::bytea order by cx, cz) b from generate_series(1, 20) conn, %s c where c.cx between 40 and 62 and c.cz between 40 and 62 group by conn) q', p_tbl) into x;
        s1 := bbench.sched(); what := 'join burst: 20 connections x 529 chunks'; cpu_ms := (s1[1] - s0[1]) / 1e6; return next;
    end loop;
end $$;
\echo -- read cost, CPU ms (median of 15)
select 'default' as storage, what, round((percentile_cont(.5) within group (order by cpu_ms))::numeric, 2) as cpu_ms from bstore.run('bstore.cc_default', 575, 15) group by what
union all select 'external', what, round((percentile_cont(.5) within group (order by cpu_ms))::numeric, 2) from bstore.run('bstore.cc_external', 575, 15) group by what
union all select 'main', what, round((percentile_cont(.5) within group (order by cpu_ms))::numeric, 2) from bstore.run('bstore.cc_main', 575, 15) group by what
union all select 'default (again)', what, round((percentile_cont(.5) within group (order by cpu_ms))::numeric, 2) from bstore.run('bstore.cc_default', 575, 15) group by what
order by 2, 1;
