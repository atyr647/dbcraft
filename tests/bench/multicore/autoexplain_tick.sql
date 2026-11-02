-- every statement of one whole entity tick that takes more than 1 ms, with its plan (auto_explain, nested); needs a bench_tick.sql population.  -v t=3001 [-v gen=1: move the players with the synthetic walk first (ibench.gen)]
\set QUIET on
select set_config('dbcraft.entity_spawner', 'off', false);
select count(mc.entity_tick(g)) from generate_series(:t - 8, :t - 1) g;
select case when :gen = 1 then ibench.gen(1.0) end;
load 'auto_explain';
set auto_explain.log_min_duration = 1;
set auto_explain.log_analyze = on;
set auto_explain.log_timing = on;
set auto_explain.log_nested_statements = on;
set client_min_messages = log;
select mc.entity_tick(:t);
