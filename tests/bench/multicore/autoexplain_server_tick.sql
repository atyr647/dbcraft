-- the slow statements (> 10 ms) of whole server ticks in inline entity mode, with the synthetic walk, through auto_explain; database prepared by split_run.sh (run it once with inline)
\set QUIET on
update mc.server_property set value = 'inline' where key = 'dbcraft.entity-mode';
select set_config('dbcraft.entity_spawner', 'off', false);
select ibench.gen(1.0); select mc.server_tick(); select ibench.drain();
select ibench.gen(1.0); select mc.server_tick(); select ibench.drain();
select ibench.gen(1.0);
load 'auto_explain';
set auto_explain.log_min_duration = 10;
set auto_explain.log_analyze = on;
set auto_explain.log_timing = on;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;
select mc.server_tick();
reset client_min_messages;
update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode';
