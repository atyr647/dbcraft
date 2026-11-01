-- CPU time (getrusage, so other workers do not matter) of every step of the entity tick separately (same order as mc.entity_tick), median and mean over T ticks, on the population the last bench_tick.sql run left behind.
-- usage: psql -v ticks=40 [-v first=1000] -f tests/bench/entity/phases.sql        (run bench_tick.sql first; PGOPTIONS='-c dbcraft.entity_lanes=off' for the exact sweep)
\set QUIET on
\if :{?first}
\else
\set first 1000
\endif
select set_config('dbcraft.entity_spawner', 'off', false);
create temp table _p (tick int, step text, ms float8);
create or replace function pg_temp.run(p_first bigint, p_ticks int) returns void language plpgsql as $$
declare t bigint; c0 float8; fl int[]; ai int[]; ids int[]; lids int[]; lanes boolean := mc.entity_lanes_enabled();
begin
    for t in p_first .. p_first + p_ticks - 1 loop
        perform set_config('dbcraft.entity_tick', t::text, false);
        truncate mc.play_out;
        c0 := public.cpu_ms(); perform mc.entity_viewers_refresh(t);                                         insert into _p values (t, '1 viewers_refresh', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); if lanes then fl := mc.entity_lane_flush(t); else fl := '{}'; end if;           insert into _p values (t, '2 lane_flush', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); ai := mc.entity_ai_ids(t);                                                      insert into _p values (t, '3 ai (wander+chase)', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); perform mc.entity_despawn(t);                                                   insert into _p values (t, '4 despawn', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); if lanes then perform mc.entity_lane_try(t, fl || ai); lids := mc.entity_lane_step(t); else lids := '{}'; end if;
                                                                                                                  insert into _p values (t, '5 lane_try+step', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); ids := mc.entity_physics_ids(t);                                                insert into _p values (t, '6 physics', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); perform mc.entity_tracker(t, ids || lids);                                      insert into _p values (t, '8 tracker', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); if lanes then perform mc.entity_lane_try(t, ids || lids); end if;                       insert into _p values (t, '7 lane_try(post)', public.cpu_ms() - c0);
        c0 := public.cpu_ms(); perform mc.entity_pickup(t);                                                    insert into _p values (t, '9 pickup', public.cpu_ms() - c0);
        insert into _p values (t, '0 awake', cardinality(ids) + cardinality(lids));
    end loop;
end $$;
select pg_temp.run(:first, 4);
delete from _p;
select pg_temp.run(:first + 4, :ticks);
select step, round(avg(ms)::numeric, 2) as mean_ms, round((percentile_cont(0.5) within group (order by ms))::numeric, 2) as p50_ms, round(min(ms)::numeric, 2) as min_ms, round(max(ms)::numeric, 2) as max_ms from _p group by step order by step;
