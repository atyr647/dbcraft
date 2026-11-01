-- Synthetic load for the WHOLE server tick (mc.server_tick): n simulated players in play state spread over a square of `side` chunks.  Every tick the "gateway"
-- inserts a position+rotation packet for a fraction of them and a client_tick_end for everybody into net.inbox, calls mc.server_tick(), and drains net.outbox
-- (net.drain_outbox) like the real gateway would.  Each statement is its own transaction.  Used by tests/bench/integration/run.sh.
create schema if not exists ibench;
create table if not exists ibench.step (tick bigint primary key, frames_out int, bytes_out bigint, rows_out int, drain_ms float8);

create or replace function ibench.setup(n int, side_chunks int, p_view int default 10) returns void language plpgsql as $$
begin
  perform setseed(0.42);
  truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
           mc.block_event, mc.tick_log, mc.server_tick_log, mc.error_log, ibench.step;
  delete from mc.player;
  update mc.server_property set value = p_view::text where key = 'view-distance';
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(i::text)::uuid, 'bot' || i, i, i, px, -60, pz, (random() * 360)::real, 0, floor(px / 16)::int, floor(pz / 16)::int,
         mc.quant(px), mc.quant(-60), mc.quant(pz), true, 0, 1, 0
    from (select i, random() * side_chunks * 16 as px, random() * side_chunks * 16 as pz from generate_series(1, n) i) g;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
  select conn_id, 'play', name, uuid, -1, entity_id, chunk_x, chunk_z, gamemode from mc.player;
  update mc.game_state set game_time = 0;
end $$;

-- what the gateway hands over this tick
create or replace function ibench.gen(frac float8) returns void language plpgsql as $$
declare i_pr int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos_rot'); i_te int := net.pkt('play', 'serverbound', 'minecraft:client_tick_end');
begin
  insert into net.inbox (conn_id, payload)
  select conn_id, proto.varint(i_pr) || proto.f64(x + (random() - 0.5) * 0.4) || proto.f64(y) || proto.f64(z + (random() - 0.5) * 0.4) || proto.f32((yaw + 1)::real) || proto.f32(pitch) || '\x01'::bytea
    from mc.player where conn_id is not null and random() < frac;
  insert into net.inbox (conn_id, payload) select conn_id, proto.varint(i_te) from mc.player where conn_id is not null;
end $$;

-- what the gateway does with the output
create or replace function ibench.drain() returns void language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); r int; b bigint;
begin
  select count(*), coalesce(sum(length(data)), 0) into r, b from net.drain_outbox();
  insert into ibench.step values ((select game_time from mc.game_state), 0, b, r, extract(epoch from clock_timestamp() - t0) * 1000)
  on conflict (tick) do update set bytes_out = excluded.bytes_out, rows_out = excluded.rows_out, drain_ms = excluded.drain_ms;
end $$;

create or replace function ibench.summary(label text, skip int default 20) returns table(line text) language sql as $$
  select format('%s | ticks %s | players %s | server_tick ms avg %s p50 %s p95 %s p99 %s max %s | process %s game %s blocks %s chunks %s drain-into-outbox %s | outbox rows/tick %s KB/tick %s drain_outbox ms %s | game phases: moves %s visibility %s',
    label, count(*), max(l.players),
    round(avg(l.ms_total)::numeric, 1), round((percentile_cont(.5) within group (order by l.ms_total))::numeric, 1), round((percentile_cont(.95) within group (order by l.ms_total))::numeric, 1),
    round((percentile_cont(.99) within group (order by l.ms_total))::numeric, 1), round(max(l.ms_total)::numeric, 1),
    round(avg(l.ms_process)::numeric, 1), round(avg(l.ms_game)::numeric, 1), round(avg(l.ms_blocks)::numeric, 1), round(avg(l.ms_chunks)::numeric, 1), round(avg(l.ms_drain)::numeric, 1),
    round(avg(s.rows_out)::numeric), round(avg(s.bytes_out)::numeric / 1024, 1), round(avg(s.drain_ms)::numeric, 1),
    round(avg(g.ms_moves)::numeric, 1), round(avg(g.ms_visibility)::numeric, 1))
  from mc.server_tick_log l join ibench.step s using (tick) join mc.tick_log g using (tick) where l.tick > skip $$;
