-- A/B of two lane-step definitions in ONE session, alternating tick by tick (even ticks: public.step_old, odd ticks: public.step_new), so the population, the cache state
-- and the machine load are shared.  Run bench_tick.sql first (it leaves the population), then: psql -v ticks=80 -f ab_step_alt.sql
-- Prints CPU ms of the step and the play_out rows / bytes it produced, per variant.
\set QUIET on
select set_config('dbcraft.entity_spawner', 'off', false);
create temp table _a (tick int, variant text, ms float8, due int, rows_out int, bytes_out bigint);
create or replace function pg_temp.run(p_first bigint, p_ticks int) returns void language plpgsql as $$
declare t bigint; c0 float8; fl int[]; ai int[]; lids int[]; v text; ms float8; due int;
begin
    for t in p_first .. p_first + p_ticks - 1 loop
        perform set_config('dbcraft.entity_tick', t::text, false);
        truncate mc.play_out;
        perform mc.entity_viewers_refresh(t);
        fl := mc.entity_lane_flush(t);
        ai := mc.entity_ai_ids(t);
        perform mc.entity_lane_try(t, fl || ai);
        select count(*) into due from mc.entity_lane l where l.slot = (t % l.every)::int and l.goal_until > t;
        v := case when t % 2 = 0 then 'old' else 'new' end;
        c0 := public.cpu_ms();
        if v = 'old' then lids := public.step_old(t); else lids := public.step_new(t); end if;
        ms := public.cpu_ms() - c0;
        insert into _a select t, v, ms, due, (select count(*) from mc.play_out), (select coalesce(sum(octet_length(data)), 0) from mc.play_out);
        perform mc.entity_tracker(t, lids);
        perform mc.entity_lane_try(t, lids);
        -- keep the rest of the tick out of the way: nothing else is measured here
    end loop;
end $$;
select pg_temp.run(:first, 6);
delete from _a;
select pg_temp.run(:first + 6, :ticks);
select variant, round(avg(ms)::numeric, 2) as mean_ms, round((percentile_cont(0.5) within group (order by ms))::numeric, 2) as p50_ms, round(avg(due)) as due, round(avg(rows_out)) as rows_out, round(avg(bytes_out)) as bytes_out,
       round((avg(ms) * 1000 / nullif(avg(due), 0))::numeric, 1) as us_per_due_mob
  from _a group by variant order by variant;
