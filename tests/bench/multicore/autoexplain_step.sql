-- plan of the statement inside public.step_new (or any function) for one tick, through auto_explain; needs a bench_tick.sql population.  -v fn=public.step_new -v t=2001
\set QUIET on
select set_config('dbcraft.entity_spawner', 'off', false);
select count(*) from (select mc.entity_tick(g) from generate_series(2000, 2000) g) q;
select set_config('dbcraft.entity_tick', :'t', false);
select mc.entity_viewers_refresh(:t);
select cardinality(mc.entity_lane_flush(:t)) as flushed;
select mc.entity_lane_try(:t, mc.entity_ai_ids(:t));
load 'auto_explain';
set auto_explain.log_min_duration = 0;
set auto_explain.log_analyze = on;
set auto_explain.log_timing = on;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;
begin;
select cardinality(:fn(:t));
rollback;
