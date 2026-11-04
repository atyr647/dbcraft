-- Alternate two implementations of the lane tick on consecutive ticks of the same population (the load of the machine cancels), CPU of the whole entity tick per version.
-- Needs mc.entity_auto_tick_v1 and the dispatching mc.entity_lane_step (dev only: the `dbcraft.entity_auto_v1` switch, see the commit message of this file).
-- usage: psql -X -q -f tests/bench/mobs2/ab_run.sql        after a bench.sql run (continues its tick numbers)
select coalesce(last_tick, 0) + 1 as first from mc.entity_clock \gset
create table if not exists public.abt (tick int, ver text, cpu float8);
delete from public.abt;
create or replace procedure public.abrun(p_from int, p_to int) language plpgsql as $$
declare a bigint[]; b bigint[];
begin
    for t in p_from..p_to loop
        perform set_config('dbcraft.entity_auto_v1', case when t % 2 = 0 then 'on' else 'off' end, false);
        a := tickbench.sched();
        perform mc.entity_tick(t);
        b := tickbench.sched();
        if t >= p_from + 10 then insert into public.abt values (t, case when t % 2 = 0 then 'v1 (before)' else 'v2 (now)' end, (b[1] - a[1]) / 1e6); end if;
        commit;
    end loop;
end $$;
call public.abrun(:first, :first + 160);
select ver, count(*), round(avg(cpu)::numeric, 2) as avg_ms, round((percentile_cont(0.5) within group (order by cpu))::numeric, 2) as p50, round(min(cpu)::numeric, 2) as min_ms from public.abt group by 1 order by 1;
