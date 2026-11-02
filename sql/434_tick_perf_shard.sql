-- OPT-IN PROTOTYPE, not called by the server: region-sharded movement.  See docs/PERF-TICK.md (parallelism).
--
-- mc.apply_player_moves_shard(tick, k, n) is mc.apply_player_moves() restricted to the connections with conn_id % n = k: it reads and deletes only their input
-- packets, updates only their player rows and broadcasts only their movement (to all viewers: mc.visible and the append to mc.play_out are shared).  Run n of
-- them from n connections at the same time (k = 0..n-1) and the n subsets are processed in parallel; they touch disjoint rows, so they do not wait for each
-- other.  Anything the sharded call cannot decide on its own (two position packets from one connection, malformed packets: the general path) raises an error:
-- a coordinator would run the general version for those connections.  The kind of sharding (here: by connection id) is a placeholder for sharding by region.
-- The shard's connections are collected into an array first and every filter is `= any (my)`: filtering on `conn_id % n = k` directly gives the planner an
-- estimate of about 2 rows and it then picks nested loops that are quadratic in the shard's size (a 5x slowdown measured for 500 players).

create or replace function mc.apply_player_moves_shard(cur_tick bigint, p_k int, p_n int) returns table(moved int, corrected int, kicked int) language plpgsql as $$
declare
  iv int := coalesce(nullif((select value::int from mc.server_property where key = 'dbcraft.player-update-interval'), 0), 2);   -- vanilla: a player's update interval is 2 ticks (EntityType.PLAYER.updateInterval(2); sendChanges runs its body when tickCount % 2 = 0; each ServerEntity counts from its own creation, so the phase differs per entity: here (tick + entity id) % interval)
  i_pos int := mc.sid('move_player_pos'); i_pr int := mc.sid('move_player_pos_rot'); i_rot int := mc.sid('move_player_rot');
  i_st int := mc.sid('move_player_status_only'); i_te int := mc.sid('client_tick_end'); i_tp int := mc.sid('accept_teleportation');
  c_pos int := mc.pid('move_entity_pos'); c_pr int := mc.pid('move_entity_pos_rot'); c_rot int := mc.pid('move_entity_rot'); c_head int := mc.pid('rotate_head');
  slow boolean; kicked_conns int[]; fin mc.move_fin[]; my int[];
begin
  my := array(select p.conn_id from mc.player p where p.conn_id is not null and p.conn_id % p_n = p_k);
  select coalesce(count(*) filter (where m.packet_id in (i_pos, i_pr)) <> count(distinct m.conn_id) filter (where m.packet_id in (i_pos, i_pr)), false)
         or coalesce(bool_or((m.packet_id = i_pos and length(m.body) <> 25) or (m.packet_id = i_pr and length(m.body) <> 33)
                             or (m.packet_id = i_rot and length(m.body) <> 9) or (m.packet_id = i_st and length(m.body) <> 1)), false)
    into slow from mc.play_in_work m where m.packet_id in (i_pos, i_pr, i_rot, i_st) and m.conn_id = any (my);
  if slow then
    raise exception 'mc.apply_player_moves_shard: this input needs the general path (two position packets or a malformed packet)';
  end if;

  -- 1. the last position, rotation and on-ground flag of each connection that sent movement input; bad = a NaN/infinite value in any of its packets.
  -- Kept in an array of mc.move_fin rows for the next few statements (no scratch table: see sql/430 on temp tables that are emptied with DELETE).
  select coalesce(array_agg(row(r.conn_id, r.x, r.y, r.z, r.has_pos, r.yaw, r.pitch, r.has_rot, r.on_ground, r.bad)::mc.move_fin), '{}') into fin from (
  with d as materialized (
    select m.conn_id, m.seq,
           case when m.packet_id = i_pos then 'p' when m.packet_id = i_pr then 'b' when m.packet_id = i_rot then 'r' else 's' end as kind,
           case when m.packet_id in (i_pos, i_pr) then proto.f64_read(m.body, 0) end as x,
           case when m.packet_id in (i_pos, i_pr) then proto.f64_read(m.body, 8) end as y,
           case when m.packet_id in (i_pos, i_pr) then proto.f64_read(m.body, 16) end as z,
           case when m.packet_id = i_pr then proto.f32_read(m.body, 24) when m.packet_id = i_rot then proto.f32_read(m.body, 0) end as yaw,
           case when m.packet_id = i_pr then proto.f32_read(m.body, 28) when m.packet_id = i_rot then proto.f32_read(m.body, 4) end as pitch,
           case when m.packet_id = i_pos then get_byte(m.body, 24) when m.packet_id = i_pr then get_byte(m.body, 32)
                when m.packet_id = i_rot then get_byte(m.body, 8) else get_byte(m.body, 0) end as flags
      from mc.play_in_work m where m.packet_id in (i_pos, i_pr, i_rot, i_st) and m.conn_id = any (my)),
  lp as (select distinct on (conn_id) conn_id, x, y, z from d where kind in ('p', 'b') order by conn_id, seq desc),
  lr as (select distinct on (conn_id) conn_id, yaw, pitch from d where kind in ('b', 'r') order by conn_id, seq desc),
  lf as (select distinct on (conn_id) conn_id, flags from d order by conn_id, seq desc),
  nb as (select conn_id from d where x in ('NaN', 'Infinity', '-Infinity') or y in ('NaN', 'Infinity', '-Infinity') or z in ('NaN', 'Infinity', '-Infinity')
                                  or yaw in ('NaN', 'Infinity', '-Infinity') or pitch in ('NaN', 'Infinity', '-Infinity') group by conn_id)
  select lf.conn_id, lp.x, lp.y, lp.z, lp.conn_id is not null as has_pos, lr.yaw, lr.pitch, lr.conn_id is not null as has_rot, (lf.flags & 1) = 1 as on_ground, nb.conn_id is not null as bad
    from lf left join lp on lp.conn_id = lf.conn_id left join lr on lr.conn_id = lf.conn_id left join nb on nb.conn_id = lf.conn_id) r;

  -- 2. rule violation: NaN / infinite values disconnect the player and ignore its input
  select coalesce(array_agg(f.conn_id), '{}') into kicked_conns from unnest(fin) f where f.bad;
  kicked := coalesce(array_length(kicked_conns, 1), 0);
  if kicked > 0 then
    perform mc.kick(c, 'multiplayer.disconnect.invalid_player_movement') from unnest(kicked_conns) c;
    fin := array(select f from unnest(fin) f where not f.bad);
  end if;

  -- 3. teleport confirmations clear the "awaiting" state
  update mc.player p set awaiting_teleport = null
    from (select conn_id, proto.varint_safe(body, 0) as tid from mc.play_in_work where packet_id = i_tp and conn_id = any (my)) a
   where p.conn_id = a.conn_id and p.awaiting_teleport = a.tid;

  -- 4. players still waiting for a teleport confirmation are ignored (like vanilla); moved too quickly: ignore the move, teleport back under a new id
  fin := array(select f from unnest(fin) f join mc.player p on p.conn_id = f.conn_id where p.awaiting_teleport is null);
  with bad as (
    select p.conn_id, p.x, p.y, p.z, p.yaw, p.pitch, p.teleport_id + 1 as tid
      from unnest(fin) f join mc.player p on p.conn_id = f.conn_id
     where f.has_pos and ((f.x - p.x) ^ 2 + (f.y - p.y) ^ 2 + (f.z - p.z) ^ 2) > 100),
  upd as (update mc.player p set teleport_id = bad.tid, awaiting_teleport = bad.tid from bad where p.conn_id = bad.conn_id returning p.conn_id),
  outq as (insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_player_position(tid, x, y, z, 0, 0, 0, yaw, pitch, 0) from bad returning 1)
  select count(*)::int into corrected from upd;
  if corrected > 0 then fin := array(select f from unnest(fin) f join mc.player p on p.conn_id = f.conn_id where p.awaiting_teleport is null); end if;

  -- 5. apply the moves (coordinates clamped like vanilla: x,z to +-3.0E7, y to +-2.0E7; pitch to +-90) and tell the viewers, in one statement.
  -- nv = every online player with its new state; mv = who must be broadcast: everybody whose stored position or rotation differs from what the
  -- viewers were last told (also players moved by other code, e.g. /tp), not only this tick's movers.
  -- The packet per mover is built once (MATERIALIZED: otherwise the expressions are inlined into the fan-out join and evaluated once per viewer),
  -- then fanned out and concatenated per viewer connection.  Frames are assembled inline from the packet ids looked up once per call (c_*); the bytes equal
  -- mc.pkt_move_entity_pos / _pos_rot / _rot / mc.pkt_rotate_head (the tests compare them); only the rare teleport fallback uses the builder.
  with nv as materialized (
    select p.conn_id, p.entity_id as eid, p.sent_qx, p.sent_qy, p.sent_qz, p.sent_yaw, p.sent_pitch, p.last_sent_tick,
           f.conn_id is not null as touched,
           case when f.has_pos then greatest(-3.0e7, least(3.0e7, f.x)) else p.x end as nx,
           case when f.has_pos then greatest(-2.0e7, least(2.0e7, f.y)) else p.y end as ny,
           case when f.has_pos then greatest(-3.0e7, least(3.0e7, f.z)) else p.z end as nz,
           case when f.has_rot then f.yaw else p.yaw end as nyaw,
           case when f.has_rot then greatest(-90, least(90, f.pitch)) else p.pitch end as npitch,
           case when f.conn_id is not null then f.on_ground else p.on_ground end as nog,
           case when f.has_pos then floor(greatest(-3.0e7, least(3.0e7, f.x)) / 16)::int else p.chunk_x end as ncx,
           case when f.has_pos then floor(greatest(-3.0e7, least(3.0e7, f.z)) / 16)::int else p.chunk_z end as ncz,
           p.vis_dirty or coalesce(f.has_pos and (floor(f.x / 16)::int <> p.chunk_x or floor(f.z / 16)::int <> p.chunk_z), false) as nvd
      from mc.player p left join unnest(fin) f on f.conn_id = p.conn_id
     where p.conn_id = any (my)),
  mv as materialized (
    select nv.*, mc.quant(nx) - sent_qx as dx, mc.quant(ny) - sent_qy as dy, mc.quant(nz) - sent_qz as dz,
           (nyaw <> sent_yaw or npitch <> sent_pitch) as rot_changed, least(greatest(cur_tick - last_sent_tick, 1), iv)::int as ticks
      from nv
     where (cur_tick + eid) % iv = 0 and (mc.quant(nx) <> sent_qx or mc.quant(ny) <> sent_qy or mc.quant(nz) <> sent_qz or nyaw <> sent_yaw or npitch <> sent_pitch)),
  pk as materialized (
    select mv.eid,
      (case when abs(dx) > 32767 or abs(dy) > 32767 or abs(dz) > 32767 then mc.pkt_teleport_entity(mv.eid, nx, ny, nz, 0, 0, 0, nyaw, npitch, nog)
            else proto.varint(octet_length(q.b) + 1) || set_byte('\x00'::bytea, 0, q.id) || q.b end)
      || case when rot_changed then proto.varint(octet_length(h.b) + 1) || set_byte('\x00'::bytea, 0, c_head) || h.b else '\x'::bytea end as data
    from mv
    cross join lateral (select
        case when (dx, dy, dz) <> (0, 0, 0) then case when rot_changed then c_pr else c_pos end else c_rot end as id,
        case when (dx, dy, dz) <> (0, 0, 0)
             then proto.varint(mv.eid) || set_byte('\x00'::bytea, 0, (case when nog then 1 else 0 end) | 2) || proto.varint(ticks)
                  || proto.i16(dx::int) || proto.i16(dy::int) || proto.i16(dz::int)
                  || case when rot_changed then set_byte('\x00'::bytea, 0, mc.angle_byte(nyaw)) || set_byte('\x00'::bytea, 0, mc.angle_byte(npitch)) else '\x'::bytea end
             else proto.varint(mv.eid) || proto.bool(nog) || set_byte('\x00'::bytea, 0, mc.angle_byte(nyaw)) || set_byte('\x00'::bytea, 0, mc.angle_byte(npitch)) end as b) q
    cross join lateral (select proto.varint(mv.eid) || set_byte('\x00'::bytea, 0, mc.angle_byte(nyaw)) as b) h),
  upd as (
    update mc.player p set x = n.nx, y = n.ny, z = n.nz, yaw = n.nyaw, pitch = n.npitch, on_ground = n.nog, chunk_x = n.ncx, chunk_z = n.ncz, vis_dirty = n.nvd,
           sent_qx = case when m.eid is not null then mc.quant(n.nx) else p.sent_qx end,
           sent_qy = case when m.eid is not null then mc.quant(n.ny) else p.sent_qy end,
           sent_qz = case when m.eid is not null then mc.quant(n.nz) else p.sent_qz end,
           sent_yaw = case when m.eid is not null then n.nyaw else p.sent_yaw end,
           sent_pitch = case when m.eid is not null then n.npitch else p.sent_pitch end,
           last_sent_tick = case when m.eid is not null then cur_tick else p.last_sent_tick end
      from nv n left join mv m on m.eid = n.eid
     where p.conn_id = n.conn_id and (n.touched or m.eid is not null)
    returning 1),
  outq as (
    insert into mc.play_out (conn_id, data)
    select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from mc.visible v join pk on pk.eid = v.target_eid group by v.viewer_conn
    returning 1)
  select (select count(*) from mv)::int into moved;

  delete from mc.play_in_work where packet_id in (i_pos, i_pr, i_rot, i_st, i_te, i_tp) and conn_id = any (my);
  return next;
end $$;
