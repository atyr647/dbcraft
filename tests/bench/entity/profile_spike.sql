-- Catch the plan of a SLOW tick: run many ticks with auto_explain logging only statements above 300 ms.
-- usage: : > $PGDATA/log; psql -f tests/bench/entity/profile_spike.sql; python3 tests/bench/entity/log_top.py $PGDATA/log; python3 tests/bench/entity/log_plan.py $PGDATA/log '<start of the statement>'
\set QUIET on
select set_config('dbcraft.entity_spawner', 'off', false);
create or replace function pg_temp.one(p_tick bigint) returns void language plpgsql as $$
begin
    update mc.player set x = x + (random() - 0.5) * 0.5, z = z + (random() - 0.5) * 0.5;
    update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int where chunk_x <> floor(x / 16)::int or chunk_z <> floor(z / 16)::int;
    truncate mc.play_out;
    perform mc.entity_tick(p_tick);
end $$;
load 'auto_explain';
set auto_explain.log_min_duration = 300;
set auto_explain.log_analyze = true;
set auto_explain.log_nested_statements = true;
select pg_temp.one(t) from generate_series(700, 760) t;
select tick, round(ms_total::numeric, 1) as total, round(ms_tracker::numeric, 1) as tracker from mc.entity_tick_log where tick between 700 and 760 and ms_total > 300 order by tick;
