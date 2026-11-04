-- On-CPU time (schedstat: load from other processes does not count) of every step of the entity tick separately, mean over T ticks, on the population the last bench.sql run left behind.
-- The steps are those of mc.entity_tick (sql/550) in the same order, one transaction per tick.  The autonomous lane tick stands for mc.entity_lane_step (no chasing mobs here).
-- usage: psql -X -q -v ticks=60 -f tests/bench/mobs2/phases.sql
\set QUIET on
\if :{?ticks}
\else
\set ticks 60
\endif
-- continues the tick sequence of the last run (a gap re-anchors every lane)
select coalesce(last_tick, 0) + 1 as first from mc.entity_clock \gset
select set_config('dbcraft.entity_spawner', 'off', false);
create temp table _p (step text, ms float8);
create or replace procedure pg_temp.run(p_first bigint, p_ticks int) language plpgsql as $$
declare t bigint; a bigint[]; fl int[]; ai int[]; ids int[]; lids int[]; prev bigint;
begin
    for t in p_first .. p_first + p_ticks - 1 loop
        perform set_config('dbcraft.entity_tick', t::text, false);
        truncate mc.play_out;
        a := tickbench.sched(); select c.last_tick into prev from mc.entity_clock c; if prev is distinct from t - 1 then perform mc.entity_auto_rebase(coalesce(prev, t - 1), t - 1); end if;
                                                                                    insert into _p values ('0 clock check', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); perform mc.entity_viewers_refresh(t);               insert into _p values ('1 viewers_refresh', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); fl := mc.entity_lane_flush(t);                      insert into _p values ('2 legacy lane flush', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); ai := mc.entity_ai_ids(t);                          insert into _p values ('3 ai (entity level)', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); perform mc.entity_despawn(t);                       insert into _p values ('4 despawn', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); perform mc.entity_auto_try(t, fl || ai); perform mc.entity_lane_try(t, fl || ai);
                                                                                    insert into _p values ('5 lane try (before)', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); lids := mc.entity_auto_tick(t);                     insert into _p values ('6 AUTO LANE TICK', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); ids := mc.entity_physics_ids(t);                    insert into _p values ('7 physics', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); perform mc.entity_tracker(t, ids || lids);          insert into _p values ('8 tracker', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); perform mc.entity_auto_try(t, ids || lids); perform mc.entity_lane_try(t, ids || lids);
                                                                                    insert into _p values ('9 lane try (after)', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); perform mc.entity_pickup_dispatch(t);               insert into _p values ('A pickup', ((tickbench.sched())[1] - a[1]) / 1e6);
        a := tickbench.sched(); update mc.entity_clock set last_tick = t;           insert into _p values ('B clock', ((tickbench.sched())[1] - a[1]) / 1e6);
        insert into _p values ('Z physics ids', cardinality(ids)), ('Z tracker ids from lanes', cardinality(lids));
        commit;
    end loop;
end $$;
call pg_temp.run(:first, 6);
delete from _p;
call pg_temp.run(:first + 6, :ticks);
select step, round(avg(ms)::numeric, 3) as mean, round((percentile_cont(0.5) within group (order by ms))::numeric, 3) as p50, round(max(ms)::numeric, 2) as max from _p group by step order by step;
select 'sum of steps (ms/tick)', round((sum(ms) / :ticks)::numeric, 3) from _p where step < 'Z';
