-- Per-statement cost of N entity ticks (pg_stat_statements with track = 'all': nested statements of the plpgsql functions are counted), on the population a bench.sql run left behind.
-- Needs shared_preload_libraries = pg_stat_statements.   usage: psql -X -q -v ticks=60 -f tests/bench/mobs2/pgss.sql
\set QUIET on
-- continues the tick sequence of the last run (a gap re-anchors every lane: not what is measured)
select coalesce(last_tick, 0) + 1 as first from mc.entity_clock \gset
\if :{?ticks}
\else
\set ticks 60
\endif
\if :{?top}
\else
\set top 30
\endif
create extension if not exists pg_stat_statements;
select set_config('dbcraft.entity_spawner', 'off', false);
create or replace procedure pg_temp.ticks(p_from bigint, p_to bigint) language plpgsql as $$ begin for g in p_from..p_to loop perform mc.entity_tick(g); commit; end loop; end $$;   -- one transaction per tick, as the server runs them
call pg_temp.ticks(:first, :first + 9);
select pg_stat_statements_reset();
call pg_temp.ticks(:first + 10, :first + 9 + :ticks);
select round((total_exec_time / :ticks)::numeric, 3) as ms_per_tick, calls / :ticks as calls_per_tick, round((mean_exec_time * 1000)::numeric, 1) as us_per_call, rows / :ticks as rows_per_tick,
       regexp_replace(left(query, 150), '\s+', ' ', 'g') as query
  from pg_stat_statements where query not like '%pg_stat_statements%' and query not like 'select count(mc.entity_tick%' order by total_exec_time desc limit :top;
