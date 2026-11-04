-- plans (with actual row counts, no timing) of every statement of one entity tick: auto_explain, nested statements.  Needs a bench.sql population.
-- usage: psql -X -q -At -f tests/bench/mobs2/ae.sql > out.txt 2>&1     then read the plan of the statement you care about (tests/bench/mobs2/ae_summary.py lists the statements)
\set QUIET on
select coalesce(last_tick, 0) + 1 as t from mc.entity_clock \gset
select set_config('dbcraft.entity_spawner', 'off', false);
load 'auto_explain';
set auto_explain.log_min_duration = 0;
set auto_explain.log_analyze = on;
set auto_explain.log_timing = off;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;
select mc.entity_tick(:t);
