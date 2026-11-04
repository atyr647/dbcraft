-- net.process_fast answers the chunk_batch_received frames of play connections in bulk, with the keep-alive and teleport answers (sql/430, docs/PERF-CAPACITY.md): the same rows as the per-packet
-- path (net.handle -> net.h_play) leaves.  Random frames: ordinary values, several in one tick (the LAST counts), NaN, zero, negative, huge, a body of fewer than 4 bytes (an error on both
-- paths: the connection is failed), mixed with keep-alive and teleport answers and with a packet the bulk path does not know (a custom payload) on other connections.
create or replace function t.ab_build() returns void language plpgsql as $$
begin
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_in, mc.play_in_work, mc.kick;
  delete from mc.player;
  update mc.game_state set game_time = 500;
  insert into net.conn (conn_id, state, name, compression, keepalive_id, keepalive_sent, teleport_id, teleport_ok, chunks_per_tick)
  select g, 'play', 'ab' || g, -1, case when g % 3 = 0 then 1000 + g end, now() - interval '2 seconds', 4, g % 2 = 0, case when g % 4 = 0 then 9 end from generate_series(1, 30) g;
end $$;
create or replace function t.ab_frames() returns void language plpgsql as $$
declare g int; k int; v real; b bytea; i_cb int := mc.sid('chunk_batch_received'); i_ka int := mc.sid('keep_alive'); i_tp int := mc.sid('accept_teleportation'); i_cp int := mc.sid('custom_payload');
begin
  perform setseed(0.23);
  for g in 1 .. 30 loop
    for k in 1 .. (random() * 3)::int loop
      v := (array[0.5, 25, 100, 0, -1, 0.005, 3.5, 'NaN', 'Infinity', 12])[1 + (random() * 9)::int]::real;
      insert into net.inbox (conn_id, payload) values (g, proto.varint(i_cb) || proto.f32(v));
    end loop;
    if g % 3 = 0 and random() < .7 then insert into net.inbox (conn_id, payload) values (g, proto.varint(i_ka) || proto.i64(1000 + g)); end if;
    if g % 5 = 0 then insert into net.inbox (conn_id, payload) values (g, proto.varint(i_tp) || proto.varint(4) || proto.f64(0) || proto.f64(0) || proto.f64(0) || proto.f32(0) || proto.f32(0)); end if;
    if g = 7 then insert into net.inbox (conn_id, payload) values (g, proto.varint(i_cb) || '\x0102'); end if;          -- too short: an error on both paths
    if g = 11 then insert into net.inbox (conn_id, payload) values (g, proto.varint(i_cp) || proto.string('minecraft:brand') || proto.string('x')); end if;      -- a kind of the ordered path: the connection's frames all go there
    if g = 13 then insert into net.inbox (conn_id, payload) values (g, proto.varint(i_cb) || proto.f32(7)); insert into net.inbox (conn_id, payload) values (g, proto.varint(i_ka) || '\x01'); end if;   -- a keep-alive too short
  end loop;
end $$;
create or replace function t.ab_digest() returns text language sql as $$
  select md5(string_agg((to_jsonb(c) - 'last_activity' - 'connected_at' - 'keepalive_sent')::text || coalesce((select 'latency' || latency_ms from net.conn x where x.conn_id = c.conn_id), ''), '|' order by c.conn_id)) from net.conn c $$;
-- the fast tick path (bulk answers)
create or replace function t.ab_fast() returns text language plpgsql as $$
begin perform t.ab_build(); perform t.ab_frames(); perform net.process_fast(); return t.ab_digest(); end $$;
-- the same frames, one at a time through the per-packet handlers, in arrival order (what net.process_fast did before the bulk path, for every kind)
create or replace function t.ab_slow() returns text language plpgsql as $$
declare r record;
begin
  perform t.ab_build(); perform t.ab_frames();
  for r in select conn_id, payload from net.inbox order by seq loop
    begin perform net.handle(r.conn_id, r.payload); exception when others then perform net.fail(r.conn_id, sqlerrm); end;
  end loop;
  return t.ab_digest();
end $$;
select t.ab_fast() is not null as ran;
select t.is_true('the scenario changes the connections (chunks_per_tick set, keep-alives answered, a connection failed)',
                 (select count(*) from net.conn where chunks_per_tick is distinct from case when conn_id % 4 = 0 then 9 end) > 10
                 and (select count(*) from net.conn where closing) >= 1 and (select count(*) from net.conn where conn_id % 3 = 0 and keepalive_id is null) >= 3);
select t.eq('bulk answers == the per-packet path, on every column of every connection', t.ab_fast(), t.ab_slow());
-- the value rule on its own
do $$ declare i_cb int := mc.sid('chunk_batch_received'); r text;
begin
  perform t.ab_build();
  truncate net.inbox;
  insert into net.inbox (conn_id, payload) values (1, proto.varint(i_cb) || proto.f32(25)), (2, proto.varint(i_cb) || proto.f32(100)), (3, proto.varint(i_cb) || proto.f32(0)),
         (4, proto.varint(i_cb) || proto.f32('NaN')), (5, proto.varint(i_cb) || proto.f32(-1)), (6, proto.varint(i_cb) || proto.f32(0.5)), (6, proto.varint(i_cb) || proto.f32(25)),
         (7, proto.varint(i_cb) || proto.f32(25)), (7, proto.varint(i_cb) || proto.f32(0.5));
  perform net.process_fast();
  select string_agg(conn_id || '=' || chunks_per_tick, ',' order by conn_id) into r from net.conn where conn_id <= 7;
  if r is distinct from '1=25,2=64,3=0.01,4=0.01,5=0.01,6=25,7=0.5' then raise exception 'FAIL chunks_per_tick values: %', r; end if;
  raise notice 'ok   chunks_per_tick: 25 -> 25, 100 -> 64 (capped), 0 / NaN / negative -> 0.01, the last of several counts (%)', r;
end $$;
-- the bulk path really ran (the batch is empty afterwards: nothing was left to the per-packet handlers)
do $$ declare i_cb int := mc.sid('chunk_batch_received');
begin
  perform t.ab_build(); truncate net.inbox;
  insert into net.inbox (conn_id, payload) select g, proto.varint(i_cb) || proto.f32(10) from generate_series(1, 20) g;
  perform net.process_fast();
  if (select count(*) from net.batch) <> 0 or (select count(*) from net.conn where chunks_per_tick = 10) <> 20 then raise exception 'FAIL the answers did not take the bulk path'; end if;
  raise notice 'ok   20 answers are applied in bulk (nothing is left in net.batch)';
end $$;
