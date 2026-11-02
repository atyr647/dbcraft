-- Crowded-world workload: N players spawned inside a square of `side` chunks (everyone sees everyone), a fraction of them walking STRAIGHT at 4.3 blocks/s
-- (0.215 blocks per tick) in a fixed per-player heading and bouncing off the edges of the square (the older synthetic walk of tests/bench/integration jitters
-- +-0.2 blocks per tick and crosses chunk borders erratically; it exaggerates chunk streaming).  Reuses ibench.setup / ibench.drain (tests/bench/integration/bench.sql).
create schema if not exists crowd;
create table if not exists crowd.dir (conn_id int primary key, hx float8 not null, hz float8 not null);
create table if not exists crowd.cfg (side float8 not null);
create table if not exists crowd.step (tick bigint primary key, cpu_ms float8, wait_ms float8, wall_ms float8, wal_bytes bigint, frames_out int, bytes_out bigint);

create or replace function crowd.setup(n int, side_chunks int, p_view int default 10) returns void language plpgsql as $$
begin
  perform ibench.setup(n, side_chunks, p_view);
  truncate crowd.dir, crowd.cfg, crowd.step;
  insert into crowd.cfg values (side_chunks * 16.0);
  insert into crowd.dir (conn_id, hx, hz)
  select conn_id, 0.215 * cos(a), 0.215 * sin(a) from (select conn_id, random() * 2 * pi() as a from mc.player where conn_id is not null) q;
end $$;

-- what the gateway hands over this tick: a position+rotation packet for a fraction of the players (their next step along their heading) and a client_tick_end for everybody
create or replace function crowd.gen(frac float8) returns void language plpgsql as $$
declare i_pr int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos_rot'); i_te int := net.pkt('play', 'serverbound', 'minecraft:client_tick_end'); s float8;
begin
  select side into s from crowd.cfg;
  update crowd.dir d set hx = case when p.x + d.hx < 0 or p.x + d.hx > s then -d.hx else d.hx end, hz = case when p.z + d.hz < 0 or p.z + d.hz > s then -d.hz else d.hz end
    from mc.player p where p.conn_id = d.conn_id and (p.x + d.hx < 0 or p.x + d.hx > s or p.z + d.hz < 0 or p.z + d.hz > s);
  insert into net.inbox (conn_id, payload)
  select p.conn_id, proto.varint(i_pr) || proto.f64(p.x + d.hx) || proto.f64(p.y) || proto.f64(p.z + d.hz)
         || proto.f32((degrees(atan2(d.hx, -d.hz)))::real) || proto.f32(0::real) || '\x01'::bytea
    from mc.player p join crowd.dir d on d.conn_id = p.conn_id where p.conn_id is not null and (frac >= 1 or random() < frac);
  insert into net.inbox (conn_id, payload) select conn_id, proto.varint(i_te) from mc.player where conn_id is not null;
end $$;

create or replace function crowd.sched() returns bigint[] language sql volatile as $$
  select string_to_array(split_part(pg_read_file('/proc/self/schedstat'), E'\n', 1), ' ')::bigint[] $$;

-- one tick through the named tick function, with on-CPU time, run-queue wait, wall time and WAL bytes
create or replace function crowd.timed_tick(fn text) returns void language plpgsql as $$
declare a bigint[]; b bigint[]; t0 timestamptz; w0 pg_lsn; cur bigint;
begin
  a := crowd.sched(); t0 := clock_timestamp(); w0 := pg_current_wal_lsn();
  execute format('select %s()', fn) into cur;
  b := crowd.sched();
  insert into crowd.step (tick, cpu_ms, wait_ms, wall_ms, wal_bytes)
  values (cur, (b[1] - a[1]) / 1e6, (b[2] - a[2]) / 1e6, extract(epoch from clock_timestamp() - t0) * 1000, pg_current_wal_lsn() - w0)
  on conflict (tick) do update set cpu_ms = excluded.cpu_ms, wait_ms = excluded.wait_ms, wall_ms = excluded.wall_ms, wal_bytes = excluded.wal_bytes;
end $$;

create or replace function crowd.summary(label text, skip int default 20) returns text language sql as $$
  select format('%s | n %s | cpu ms avg %s p50 %s p95 %s p99 %s max %s | wall avg %s p99 %s | ticks over 50ms (wall) %s | wal KB/tick %s | out rows %s KB %s',
    label, count(*), round(avg(s.cpu_ms)::numeric, 1), round((percentile_cont(.5) within group (order by s.cpu_ms))::numeric, 1),
    round((percentile_cont(.95) within group (order by s.cpu_ms))::numeric, 1), round((percentile_cont(.99) within group (order by s.cpu_ms))::numeric, 1), round(max(s.cpu_ms)::numeric, 1),
    round(avg(s.wall_ms)::numeric, 1), round((percentile_cont(.99) within group (order by s.wall_ms))::numeric, 1), count(*) filter (where s.wall_ms > 50),
    round(avg(s.wal_bytes)::numeric / 1024, 1), round(avg(i.rows_out)::numeric), round(avg(i.bytes_out)::numeric / 1024))
  from crowd.step s left join ibench.step i using (tick) where s.tick > skip $$;
