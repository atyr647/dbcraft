-- every statement (nested) of one entity tick with its duration and plan (auto_explain, threshold 0): tests/bench/mobs2/ae_summary.py aggregates it.  Needs a bench.sql population.
-- usage: psql -X -q -At -v t=3010 -f tests/bench/mobs2/ae.sql > out.txt 2>&1
\set QUIET on
select set_config('dbcraft.entity_spawner', 'off', false);
select count(mc.entity_tick(g)) from generate_series(:t - 8, :t - 1) g;
load 'auto_explain';
set auto_explain.log_min_duration = 0;
set auto_explain.log_analyze = on;
set auto_explain.log_timing = on;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;
select mc.entity_tick(:t);
