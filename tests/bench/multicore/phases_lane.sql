-- CPU time of lane_try, lane_step and the tracker call for the step ids separately, on the population the last bench_tick.sql run left behind.
\set QUIET on
\if :{?first}
\else
\set first 5000
\endif
select set_config('dbcraft.entity_spawner', 'off', false);
create temp table _p (tick int, step text, ms float8, n int);
create or replace function pg_temp.run(p_first bigint, p_ticks int) returns void language plpgsql as $$
declare t bigint; c0 float8; fl int[]; ai int[]; lids int[]; nn int;
begin
    for t in p_first .. p_first + p_ticks - 1 loop
        perform set_config('dbcraft.entity_tick', t::text, false);
        truncate mc.play_out;
        perform mc.entity_viewers_refresh(t);
        fl := mc.entity_lane_flush(t);
        ai := mc.entity_ai_ids(t);
        c0 := public.cpu_ms(); nn := mc.entity_lane_try(t, fl || ai);  insert into _p values (t, 'a lane_try', public.cpu_ms() - c0, nn);
        c0 := public.cpu_ms(); lids := mc.entity_lane_step(t);          insert into _p values (t, 'b lane_step', public.cpu_ms() - c0, (select count(*) from mc.entity_lane l where l.slot = (t % l.every)::int and l.goal_until > t));
        c0 := public.cpu_ms(); perform mc.entity_tracker(t, lids);      insert into _p values (t, 'c tracker(sync ids)', public.cpu_ms() - c0, cardinality(lids));
    end loop;
end $$;
select pg_temp.run(:first, 4);
delete from _p;
select pg_temp.run(:first + 4, 40);
select step, round(avg(ms)::numeric, 2) as mean_ms, round(avg(n)) as n from _p group by step order by step;
select count(*) as lanes, count(*) filter (where chase) as chasers from mc.entity_lane;
select (select count(*) from mc.entity where not deep_sleep) as awake, (select count(*) from mc.entity where lane_until > 0) as in_lane,
       (select count(*) from mc.entity_cell_viewer) as cell_viewers, (select count(*) from mc.entity_viewer_cell) as viewer_cells;
