-- A/B of two definitions of one function through the WHOLE entity tick, alternating tick by tick in one session (the definition is swapped with CREATE OR REPLACE between ticks).
-- usage: psql -v first=2000 -v ticks=120 (env OLDF=/tmp/old.sql NEWF=/tmp/new.sql) -f ab_tick.sql     (run bench_tick.sql first; the two files hold the complete CREATE OR REPLACE statements)
-- Prints CPU ms of mc.entity_tick (mean / p50 / p99), awake count and play_out rows / bytes for each variant.
\set QUIET on
select set_config('dbcraft.entity_spawner', 'off', false);
\set oldsrc `cat "$OLDF"`
\set newsrc `cat "$NEWF"`
create temp table _src (variant text primary key, src text);
insert into _src values ('old', :'oldsrc'), ('new', :'newsrc');
create temp table _a (tick int, variant text, ms float8, rows_out int, bytes_out bigint);
create or replace function pg_temp.run(p_first bigint, p_ticks int, p_rec boolean) returns void language plpgsql as $$
declare t bigint; c0 float8; v text; ms float8;
begin
    for t in p_first .. p_first + p_ticks - 1 loop
        v := case when t % 2 = 0 then 'old' else 'new' end;
        execute (select src from _src where variant = v);
        truncate mc.play_out;
        c0 := public.cpu_ms();
        perform mc.entity_tick(t);
        ms := public.cpu_ms() - c0;
        if p_rec then insert into _a select t, v, ms, (select count(*) from mc.play_out), (select coalesce(sum(octet_length(data)), 0) from mc.play_out); end if;
    end loop;
end $$;
select pg_temp.run(:first, 6, false);
select pg_temp.run(:first + 6, :ticks, true);
select variant, round(avg(ms)::numeric, 2) as mean_ms, round((percentile_cont(0.5) within group (order by ms))::numeric, 2) as p50_ms, round((percentile_cont(0.99) within group (order by ms))::numeric, 2) as p99_ms,
       round(avg(rows_out)) as rows_out, round(avg(bytes_out)) as bytes_out from _a group by variant order by variant;
