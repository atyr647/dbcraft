-- plan with timing of the autonomous lane tick of ONE tick on the population the last bench left
select coalesce(last_tick, 0) + 1 as t from mc.entity_clock \gset
select set_config('dbcraft.entity_spawner', 'off', false);
load 'auto_explain';
set auto_explain.log_min_duration = 0;
set auto_explain.log_analyze = on;
set auto_explain.log_timing = on;
set auto_explain.log_buffers = on;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;
select mc.entity_auto_tick(:t);
