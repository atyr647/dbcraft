-- Per-tick on-CPU time of the backend, read from /proc/self/schedstat (field 1: ns on CPU, field 2: ns waiting on a run queue).
-- Wall time inflates when other processes load the machine; on-CPU time barely does, so it is the better number for comparing code changes.
-- Needs a superuser (pg_read_file).  Used by tests/bench/tick/run.sh.
create schema if not exists tickbench;
create table if not exists tickbench.step (tick bigint primary key, cpu_ms float8, wait_ms float8, wall_ms float8);
create or replace function tickbench.sched() returns bigint[] language sql volatile as $$
  select string_to_array(split_part(pg_read_file('/proc/self/schedstat'), E'\n', 1), ' ')::bigint[] $$;
create or replace function tickbench.timed_tick() returns void language plpgsql as $$
declare a bigint[]; b bigint[]; t0 timestamptz; cur bigint;
begin
  a := tickbench.sched(); t0 := clock_timestamp();
  cur := mc.server_tick();
  b := tickbench.sched();
  insert into tickbench.step values (cur, (b[1] - a[1]) / 1e6, (b[2] - a[2]) / 1e6, extract(epoch from clock_timestamp() - t0) * 1000)
  on conflict (tick) do update set cpu_ms = excluded.cpu_ms, wait_ms = excluded.wait_ms, wall_ms = excluded.wall_ms;
end $$;
create or replace function tickbench.summary(label text, skip int default 20) returns text language sql as $$
  select format('%s | n %s | wall avg %s p10 %s p50 %s p95 %s p99 %s max %s | cpu avg %s p10 %s p50 %s p95 %s p99 %s | runq-wait avg %s | phases process %s game %s blocks %s chunks %s drain %s | out rows %s KB %s',
    label, count(*),
    round(avg(s.wall_ms)::numeric, 1), round((percentile_cont(.1) within group (order by s.wall_ms))::numeric, 1), round((percentile_cont(.5) within group (order by s.wall_ms))::numeric, 1), round((percentile_cont(.95) within group (order by s.wall_ms))::numeric, 1),
    round((percentile_cont(.99) within group (order by s.wall_ms))::numeric, 1), round(max(s.wall_ms)::numeric, 1),
    round(avg(s.cpu_ms)::numeric, 1), round((percentile_cont(.1) within group (order by s.cpu_ms))::numeric, 1), round((percentile_cont(.5) within group (order by s.cpu_ms))::numeric, 1), round((percentile_cont(.95) within group (order by s.cpu_ms))::numeric, 1),
    round((percentile_cont(.99) within group (order by s.cpu_ms))::numeric, 1), round(avg(s.wait_ms)::numeric, 1),
    round(avg(l.ms_process)::numeric, 1), round(avg(l.ms_game)::numeric, 1), round(avg(l.ms_blocks)::numeric, 1), round(avg(l.ms_chunks)::numeric, 1), round(avg(l.ms_drain)::numeric, 1),
    round(avg(l.frames_out)::numeric), round(avg(i.bytes_out)::numeric / 1024))
  from tickbench.step s join mc.server_tick_log l using (tick) join ibench.step i using (tick) where s.tick > skip $$;
