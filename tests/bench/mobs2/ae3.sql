-- warm the generic plan, then the plan with timing of the heaviest slot ticks
select coalesce(last_tick, 0) + 1 as t from mc.entity_clock \gset
select set_config('dbcraft.entity_spawner', 'off', false);
select mc.entity_auto_tick(g) from generate_series(:t, :t + 12) g;
load 'auto_explain';
set auto_explain.log_min_duration = 3;
set auto_explain.log_analyze = on;
set auto_explain.log_timing = on;
set auto_explain.log_buffers = on;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;
select mc.entity_auto_tick(g) from generate_series(:t + 13, :t + 14) g;
