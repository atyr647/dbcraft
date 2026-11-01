-- Deterministic A/B harness for the whole server tick.  Loads the integration benchmark's setup (ibench.setup) and adds:
--   bbench.gen(t, frac, mode)   the gateway's input for tick t, a pure function of (connection, t, position): both implementations see identical input
--   bbench.run(impl, ticks, frac, mode, txmode)   drives gen -> tick -> drain server-side, committing like the real gateway
-- impl:   'base' = mc.server_tick(), 'batched' = mc.server_tick_batched(), 'noop' = nothing (subtracted when counting statements)
-- txmode: 'split' = gen, tick and drain each commit separately (what tests/bench/integration does); 'one' = one transaction per tick (what the PL/Python gateway does)
-- mode:   'dither' = every moving player takes a +-0.2 step (stresses chunk borders: players re-cross them constantly),
--         'walk'   = every moving player walks straight at 0.22 blocks per tick (a realistic walk: a border crossing every ~70 ticks)
\ir ../integration/bench.sql
create schema if not exists bbench;
drop table if exists bbench.step;
drop table if exists bbench.run_log;
create table bbench.step (run_id int, tick int, tick_ms float8, drain_ms float8, frames_out int, bytes_out bigint, frames_in int);
create table bbench.run_log (run_id int primary key, impl text, players int, frac float8, mode text, txmode text, started timestamptz default now(),
                                          wal_bytes bigint, statements bigint, rows_ins bigint, rows_upd bigint, rows_del bigint, hot_upd bigint, wall_ms float8);

create or replace function bbench.rnd(c int, t int, s int) returns float8 language sql immutable parallel safe as $$
  select (('x' || substr(md5(c::text || ':' || t::text || ':' || s::text), 1, 8))::bit(32)::bigint)::float8 / 4294967296.0 $$;

create or replace function bbench.gen(t int, frac float8, mode text) returns int language plpgsql as $$
declare i_pr int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos_rot'); i_te int := net.pkt('play', 'serverbound', 'minecraft:client_tick_end'); n int;
begin
  insert into net.inbox (conn_id, payload)
  select conn_id, proto.varint(i_pr)
         || proto.f64(case mode when 'walk' then x + 0.22 * cos(conn_id) else x + (bbench.rnd(conn_id, t, 1) - 0.5) * 0.4 end) || proto.f64(y)
         || proto.f64(case mode when 'walk' then z + 0.22 * sin(conn_id) else z + (bbench.rnd(conn_id, t, 2) - 0.5) * 0.4 end)
         || proto.f32((yaw + 1)::real) || proto.f32(pitch) || '\x01'::bytea
    from mc.player where conn_id is not null and bbench.rnd(conn_id, t, 0) < frac order by conn_id;
  get diagnostics n = row_count;
  insert into net.inbox (conn_id, payload) select conn_id, proto.varint(i_te) from mc.player where conn_id is not null order by conn_id;
  return n;
end $$;

create or replace procedure bbench.run(p_run int, impl text, ticks int, frac float8, mode text default 'dither', txmode text default 'split', skip int default 20)
language plpgsql as $$
declare t int; t0 timestamptz; t1 timestamptz; ms float8; dms float8; fo int; bo bigint; fi int; w0 pg_lsn; w1 pg_lsn := null; wall0 timestamptz;
        s0 bigint; s1 bigint; players int;
begin
  select count(*) into players from mc.player where conn_id is not null;
  insert into bbench.run_log (run_id, impl, players, frac, mode, txmode) values (p_run, impl, players, frac, mode, txmode);
  commit;
  for t in 1..ticks loop
    if t = skip + 1 then
      commit; perform pg_stat_statements_reset(); perform pg_sleep(0.2); w0 := pg_current_wal_lsn(); wall0 := clock_timestamp();
    end if;
    fi := bbench.gen(t, frac, mode);
    if txmode = 'split' then commit; end if;
    t0 := clock_timestamp();
    if impl = 'base' then perform mc.server_tick(); elsif impl = 'batched' then perform mc.server_tick_batched(); end if;
    t1 := clock_timestamp();
    if txmode = 'split' then commit; end if;
    select count(*), coalesce(sum(length(d.data)), 0) into fo, bo from net.drain_outbox() d;
    dms := extract(epoch from clock_timestamp() - t1) * 1000;
    commit;
    ms := extract(epoch from t1 - t0) * 1000;
    insert into bbench.step values (p_run, t, ms, dms, fo, bo, fi);
    commit;
  end loop;
  w1 := pg_current_wal_lsn();
  update bbench.run_log set wal_bytes = pg_wal_lsn_diff(w1, w0), wall_ms = extract(epoch from clock_timestamp() - wall0) * 1000 where run_id = p_run;
  commit;
end $$;

-- summary of one run (skip warm-up ticks): the tick, the drain, volumes
create or replace function bbench.summary(p_run int, skip int default 20) returns table(line text) language sql as $$
  select format('%s | %s ticks | tick ms avg %s p50 %s p95 %s p99 %s max %s | drain_outbox ms %s | frames %s KB %s per tick | WAL KB/tick %s',
    r.impl, count(*), round(avg(s.tick_ms)::numeric, 2), round((percentile_cont(.5) within group (order by s.tick_ms))::numeric, 2),
    round((percentile_cont(.95) within group (order by s.tick_ms))::numeric, 2), round((percentile_cont(.99) within group (order by s.tick_ms))::numeric, 2),
    round(max(s.tick_ms)::numeric, 1), round(avg(s.drain_ms)::numeric, 2), round(avg(s.frames_out)), round(avg(s.bytes_out)::numeric / 1024, 1),
    round(r.wal_bytes::numeric / nullif(count(*), 0) / 1024, 1))
  from bbench.step s join bbench.run_log r using (run_id) where s.run_id = p_run and s.tick > skip group by r.impl, r.wal_bytes $$;
