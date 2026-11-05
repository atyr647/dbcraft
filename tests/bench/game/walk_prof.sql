-- CPU time per tick and waypoint packet counts for the walking bench (tests/bench/game/walk_prof.sh).  The backend's on-CPU nanoseconds come from /proc/self/schedstat
-- (read by the backend itself through pg_read_file, so the figure is the CPU of the session that runs mc.tick(), not wall time on a shared machine).
create schema if not exists bench;
create table if not exists bench.cpu (tick bigint primary key, cpu_ns bigint);
create or replace function bench.cpu_ns() returns bigint language sql volatile as $$ select split_part(pg_read_file('/proc/self/schedstat'), ' ', 1)::bigint $$;

-- number and bytes of the waypoint packets (packet id 141) in the output of the tick: the frames of mc.play_out rows are VarInt length | VarInt id | body
create table if not exists bench.wpn (tick bigint primary key, n int, bytes bigint, track int, upd int, untrack int);
create or replace function bench.count_wp() returns void language plpgsql as $$
declare r record; d bytea; p int; len int; sh int; b int; n int := 0; byt bigint := 0; tr int := 0; up int := 0; un int := 0; start int; op int;
begin
  for r in select data from mc.play_out loop
    d := r.data; p := 0;
    while p < length(d) loop
      len := 0; sh := 0;
      loop b := get_byte(d, p); p := p + 1; len := len | ((b & 127) << sh); sh := sh + 7; exit when b < 128; end loop;
      start := p;
      if get_byte(d, p) = 141 and get_byte(d, p + 1) = 1 then
        n := n + 1; byt := byt + len + (case when len < 128 then 1 else 2 end);
        op := get_byte(d, p + 2); if op = 0 then tr := tr + 1; elsif op = 1 then un := un + 1; else up := up + 1; end if;
      end if;
      p := start + len;
    end loop;
  end loop;
  insert into bench.wpn values ((select game_time from mc.game_state), n, byt, tr, up, un) on conflict (tick) do update set n = excluded.n, bytes = excluded.bytes, track = excluded.track, upd = excluded.upd, untrack = excluded.untrack;
end $$;

create or replace function bench.cpu_summary(label text, skip int default 20) returns table(line text) language sql as $$
  select format('%s | ticks %s | CPU ms/tick avg %s p50 %s p95 %s max %s | tick wall ms avg %s | wp packets/tick %s (track %s upd %s untrack %s) bytes/tick %s | out rows/tick %s KB/tick %s',
    label, count(*), round((avg(c.cpu_ns) / 1e6)::numeric, 2), round((percentile_cont(.5) within group (order by c.cpu_ns) / 1e6)::numeric, 2),
    round((percentile_cont(.95) within group (order by c.cpu_ns) / 1e6)::numeric, 2), round((max(c.cpu_ns) / 1e6)::numeric, 2), round(avg(l.ms_total)::numeric, 1),
    round(avg(w.n)), round(avg(w.track)), round(avg(w.upd)), round(avg(w.untrack)), round(avg(w.bytes)), round(avg(s.out_rows)), round(avg(s.out_bytes)::numeric / 1024, 1))
  from bench.cpu c join mc.tick_log l on l.tick = c.tick join bench.step s on s.tick = c.tick left join bench.wpn w on w.tick = c.tick where c.tick > skip $$;
