-- Synthetic load for mc.tick(): n simulated players spread over a square of `side` chunks, a fraction of them sending a pos_rot packet + client_tick_end
-- every tick.  Each statement below runs in its own transaction (autocommit), like the real server: generate input, tick, drain output.
-- Used by tests/bench/game/run.sh.
create schema if not exists bench;

create or replace function bench.setup(n int, side_chunks int) returns void language plpgsql as $$
begin
  perform setseed(0.42);
  truncate mc.play_out, mc.play_in, mc.visible, mc.kick, mc.tick_log;
  delete from mc.player;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick)
  select md5(i::text)::uuid, 'bot' || i, i, i, px, 64, pz, (random() * 360)::real, 0, floor(px / 16)::int, floor(pz / 16)::int,
         mc.quant(px), mc.quant(64), mc.quant(pz), true, 0
    from (select i, random() * side_chunks * 16 as px, random() * side_chunks * 16 as pz from generate_series(1, n) i) g;
  update mc.game_state set game_time = 0;
  update mc.server_property set value = '10' where key = 'view-distance';
  -- the visibility layer (sql/900-910, dbcraft.vanilla-tracker) keeps its state per player: bots are players that were created at tick 0 and whose clients asked for the server's view distance
  -- (a client that never asks has vanilla's default 2, a circle of 32 blocks); a no-op on a database without the layer
  if to_regprocedure('mc.vis_on()') is not null then
    update mc.player set trk_start = 0, trk_ground = true, trk_sync = -2, vis_wake = null,
           view_distance_req = 10, vis_x = x, vis_z = z, wp_state = 1, wp_bx = floor(x)::int, wp_by = floor(y)::int, wp_bz = floor(z)::int, wp_cx = chunk_x, wp_cz = chunk_z,
           attr_seen = mc.attr_std_seen(), attr_gm = gamemode, attr_spr = false, sent_equip = array['', '', '', '', '', ''], sent_held = 0, equip_dirty = false
     where conn_id is not null;
    insert into mc.vtrk (entity_id, base_x, base_y, base_z, sent_yb, sent_pb, sent_hb)
    select entity_id, x, y, z, mc.angle_byte(yaw), 0, mc.angle_byte(yaw) from mc.player where conn_id is not null
    on conflict (entity_id) do update set base_x = excluded.base_x, base_y = excluded.base_y, base_z = excluded.base_z, sent_yb = excluded.sent_yb, sent_pb = 0, sent_hb = excluded.sent_hb;
  end if;
end $$;

create table if not exists bench.step (tick bigint primary key, gen_ms float8, drain_ms float8, out_rows int, out_bytes bigint);

-- 1. what the gateway would hand over this tick: each moving player's position+rotation packet, then client_tick_end for everyone
create or replace function bench.gen(frac float8) returns void language plpgsql as $$
begin
  insert into mc.play_in (conn_id, packet_id, body)
  select conn_id, mc.sid('move_player_pos_rot'),
         proto.f64(x + (random() - 0.5) * 0.4) || proto.f64(y) || proto.f64(z + (random() - 0.5) * 0.4) || proto.f32((yaw + 1)::real) || proto.f32(pitch) || '\x01'::bytea
    from mc.player where conn_id is not null and random() < frac;
  insert into mc.play_in (conn_id, packet_id, body) select conn_id, mc.sid('client_tick_end'), '\x'::bytea from mc.player where conn_id is not null;
end $$;

-- 3. what the gateway would do with the output: read it and delete it
create or replace function bench.drain() returns void language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); r int; b bigint;
begin
  select count(*), coalesce(sum(length(data)), 0) into r, b from mc.play_out;
  delete from mc.play_out;
  insert into bench.step values ((select game_time from mc.game_state), 0, extract(epoch from clock_timestamp() - t0) * 1000, r, b)
  on conflict (tick) do update set drain_ms = excluded.drain_ms, out_rows = excluded.out_rows, out_bytes = excluded.out_bytes;
end $$;

create or replace function bench.summary(label text, skip int default 20) returns table(line text) language sql as $$
  select format('%s | ticks %s | players %s | tick ms avg %s p50 %s p95 %s p99 %s max %s | moves %s vis %s chat %s misc %s ka %s time %s | out rows/tick %s KB/tick %s drain ms %s | corrections %s kicks %s',
    label, count(*), max(l.players),
    round(avg(ms_total)::numeric, 1), round((percentile_cont(.5) within group (order by ms_total))::numeric, 1), round((percentile_cont(.95) within group (order by ms_total))::numeric, 1),
    round((percentile_cont(.99) within group (order by ms_total))::numeric, 1), round(max(ms_total)::numeric, 1),
    round(avg(ms_moves)::numeric, 1), round(avg(ms_visibility)::numeric, 1), round(avg(ms_chat)::numeric, 2), round(avg(ms_misc)::numeric, 2), round(avg(ms_keepalive)::numeric, 2), round(avg(ms_time)::numeric, 2),
    round(avg(s.out_rows)::numeric), round(avg(s.out_bytes)::numeric / 1024, 1), round(avg(s.drain_ms)::numeric, 1), sum(corrections), sum(kicks))
  from mc.tick_log l join bench.step s using (tick) where l.tick > skip $$;
