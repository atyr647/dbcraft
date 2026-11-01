-- Profile one entity tick in a WARM session: ten ordinary ticks first (plans cached), then auto_explain on the last one.
-- usage: : > $PGDATA/log; psql -f tests/bench/entity/profile_tick.sql; python3 tests/bench/entity/log_top.py $PGDATA/log
-- (run bench_tick.sql first to build the world and the population; the first ticks here continue from tick 601)
\set QUIET on
create or replace function pg_temp.one(p_tick bigint) returns void language plpgsql as $$
begin
    update mc.player set x = x + (random() - 0.5) * 0.5, z = z + (random() - 0.5) * 0.5;
    update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int where chunk_x <> floor(x / 16)::int or chunk_z <> floor(z / 16)::int;
    truncate mc.play_out;
    perform mc.entity_tick(p_tick);
end $$;
select pg_temp.one(t) from generate_series(601, 612) t;
load 'auto_explain';
set auto_explain.log_min_duration = 0.5;
set auto_explain.log_analyze = true;
set auto_explain.log_nested_statements = true;
select pg_temp.one(613);
reset auto_explain.log_min_duration;
select tick, round(ms_total::numeric, 1) as total, round(ms_ai::numeric, 1) as viewers_ai, round(ms_physics::numeric, 1) as physics, round(ms_tracker::numeric, 1) as tracker, awake
  from mc.entity_tick_log where tick between 606 and 613 order by tick;
