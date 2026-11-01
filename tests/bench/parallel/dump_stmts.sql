-- Dumps pg_stat_statements of the current database (per tick = divided by the number of measured ticks given in :ticks) as unit-separator separated text.
-- usage: psql -X -q -At -F $'\x1f' -v ticks=80 -f dump_stmts.sql -o /tmp/stmts.tsv
select round(((total_exec_time + total_plan_time) / :ticks)::numeric, 3) as ms_per_tick,
       round((total_exec_time / :ticks)::numeric, 3) as exec_ms,
       round((total_plan_time / :ticks)::numeric, 3) as plan_ms,
       calls / :ticks as calls_per_tick,
       rows / :ticks as rows_per_tick,
       regexp_replace(query, '\s+', ' ', 'g') as query
  from pg_stat_statements
 where dbid = (select oid from pg_database where datname = current_database())
   and query not like '%pg_stat_statements%' and query not like 'select ibench.%' and query not like 'select tickbench.%'
 order by (total_exec_time + total_plan_time) desc;
