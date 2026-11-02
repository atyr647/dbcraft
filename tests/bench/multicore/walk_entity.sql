-- The entity tick after the synthetic walk of tests/bench/integration/bench.sql moved the players (ibench.gen), tick by tick, with the phase breakdown of mc.entity_tick_log.
-- usage: psql -v first=800000 -v ticks=40 -f walk_entity.sql      (database prepared by split_run.sh; entity-mode off)
\set QUIET on
select set_config('dbcraft.entity_spawner', 'off', false);
create temp table _w (tick bigint, gen_ms float8, ent_ms float8);
create or replace function pg_temp.run(p_first bigint, p_ticks int) returns void language plpgsql as $$
declare t bigint; c0 timestamptz; c1 timestamptz; c2 timestamptz;
begin
    for t in p_first .. p_first + p_ticks - 1 loop
        c0 := clock_timestamp();
        perform ibench.gen(1.0);
        c1 := clock_timestamp();
        truncate mc.play_out;
        perform mc.entity_tick(t);
        c2 := clock_timestamp();
        insert into _w values (t, extract(epoch from c1 - c0) * 1000, extract(epoch from c2 - c1) * 1000);
    end loop;
end $$;
select pg_temp.run(:first, 10);
delete from _w; delete from mc.entity_tick_log;
select pg_temp.run(:first + 10, :ticks);
select round(avg(ent_ms)::numeric, 1) as entity_ms, round((percentile_cont(.5) within group (order by ent_ms))::numeric, 1) as p50, round(max(ent_ms)::numeric, 1) as max, round(avg(gen_ms)::numeric, 1) as gen_ms from _w;
select round(avg(ms_ai)::numeric, 1) as ai_lanes_viewers, round(avg(ms_physics)::numeric, 1) as physics, round(avg(ms_tracker)::numeric, 1) as tracker, round(avg(ms_pickup)::numeric, 1) as pickup, round(avg(ms_total)::numeric, 1) as total from mc.entity_tick_log;
select (select count(*) from mc.entity_cell_viewer) as cell_viewer_rows, (select count(*) from mc.entity_lane) as lanes, (select count(*) from mc.entity) as entities;
select tick, round(ent_ms::numeric, 1) as ent_ms from _w order by ent_ms desc limit 6;
select t.tick, t.ms_ai, t.ms_physics, t.ms_tracker, t.awake, t.sent from mc.entity_tick_log t order by ms_total desc limit 4;
