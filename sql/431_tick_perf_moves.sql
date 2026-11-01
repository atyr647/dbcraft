-- Tick performance, part 2: movement.  See docs/PERF-TICK.md.
--
-- mc.apply_player_moves() is split in two:
--   * mc.apply_player_moves_general(): the original implementation, byte for byte (an exact copy of sql/340's function under a new name).  It scans every
--     connection's packets in order with window functions, which the two violation rules need ("two position packets between two client_tick_end"
--     and malformed packets) and is therefore the only place those rules are implemented.
--   * mc.apply_player_moves(): the fast path used when none of those rules can fire: every position-carrying packet is well-formed and no connection sent
--     two of them in the tick (the normal case: one position packet and one client_tick_end per tick).  Then
--       - decode + last-value-per-connection is one scan with DISTINCT ON (no window functions, no indexed temp table, no ANALYZE),
--       - the moved-too-quickly correction stays its own statement (its packets must precede the broadcast in the player's queue, as before),
--       - applying the move and broadcasting it are ONE statement: mc.player is read once and updated once (it used to be read three times and updated twice),
--     with the same results as the general version (tests/sql/36_game_tick.sql, 410_integration_replay.sql and tests/sql/431_tick_perf_moves.sql compare them).
--   Anything else falls back to the general version.

create or replace function mc.apply_player_moves_general(cur_tick bigint) returns table(moved int, corrected int, kicked int) language plpgsql as $$
declare
  i_pos int := mc.sid('move_player_pos'); i_pr int := mc.sid('move_player_pos_rot'); i_rot int := mc.sid('move_player_rot');
  i_st int := mc.sid('move_player_status_only'); i_te int := mc.sid('client_tick_end'); i_tp int := mc.sid('accept_teleportation');
  kicked_conns int[];
  c_pos int := mc.pid('move_entity_pos'); c_pr int := mc.pid('move_entity_pos_rot'); c_rot int := mc.pid('move_entity_rot'); c_head int := mc.pid('rotate_head');
begin
  create temp table if not exists _mv (conn_id int, seq bigint, kind "char", x float8, y float8, z float8, yaw real, pitch real, flags int, seg int, pos_n int, bad boolean) on commit delete rows;
  create index if not exists _mv_conn on _mv (conn_id, seq);
  create temp table if not exists _fin (conn_id int primary key, x float8, y float8, z float8, has_pos boolean, yaw real, pitch real, has_rot boolean, on_ground boolean) on commit delete rows;
  delete from _mv; delete from _fin;

  perform mc.prof('start');
  -- 1. decode (fixed sizes: pos 25 bytes, pos_rot 33, rot 9, status 1; anything else is malformed and kicked)
  insert into _mv
  select conn_id, seq, kind, x, y, z, yaw, pitch, flags, seg,
         case when kind in ('p', 'b') then row_number() over (partition by conn_id, seg, kind in ('p', 'b') order by seq) end,
         kind = 'x' or coalesce(x in ('NaN', 'Infinity', '-Infinity') or y in ('NaN', 'Infinity', '-Infinity') or z in ('NaN', 'Infinity', '-Infinity')
                                or yaw in ('NaN', 'Infinity', '-Infinity') or pitch in ('NaN', 'Infinity', '-Infinity'), false)
  from (
    select d.*, coalesce(sum((kind = 't')::int) over (partition by conn_id order by seq rows between unbounded preceding and 1 preceding), 0) as seg
    from (
      select m.conn_id, m.seq,
             case when m.packet_id = i_pos then case when length(m.body) = 25 then 'p' else 'x' end
                  when m.packet_id = i_pr  then case when length(m.body) = 33 then 'b' else 'x' end
                  when m.packet_id = i_rot then case when length(m.body) = 9  then 'r' else 'x' end
                  when m.packet_id = i_st  then case when length(m.body) = 1  then 's' else 'x' end
                  else 't' end as kind,
             case when length(m.body) in (25, 33) and m.packet_id in (i_pos, i_pr) then proto.f64_read(m.body, 0) end as x,
             case when length(m.body) in (25, 33) and m.packet_id in (i_pos, i_pr) then proto.f64_read(m.body, 8) end as y,
             case when length(m.body) in (25, 33) and m.packet_id in (i_pos, i_pr) then proto.f64_read(m.body, 16) end as z,
             case when m.packet_id = i_pr and length(m.body) = 33 then proto.f32_read(m.body, 24) when m.packet_id = i_rot and length(m.body) = 9 then proto.f32_read(m.body, 0) end as yaw,
             case when m.packet_id = i_pr and length(m.body) = 33 then proto.f32_read(m.body, 28) when m.packet_id = i_rot and length(m.body) = 9 then proto.f32_read(m.body, 4) end as pitch,
             case when m.packet_id = i_pos and length(m.body) = 25 then get_byte(m.body, 24) when m.packet_id = i_pr and length(m.body) = 33 then get_byte(m.body, 32)
                  when m.packet_id = i_rot and length(m.body) = 9 then get_byte(m.body, 8) when m.packet_id = i_st and length(m.body) = 1 then get_byte(m.body, 0) end as flags
        from mc.play_in_work m where m.packet_id in (i_pos, i_pr, i_rot, i_st, i_te)) d) s;

  perform mc.prof('1 decode + windows');
  -- 2. rule violations: disconnect, and ignore the rest of that connection's packets
  select coalesce(array_agg(distinct conn_id), '{}') into kicked_conns from _mv where pos_n > 1 or bad;
  perform mc.kick(c, 'multiplayer.disconnect.invalid_player_movement') from unnest(kicked_conns) c;
  kicked := coalesce(array_length(kicked_conns, 1), 0);
  delete from _mv where conn_id = any (kicked_conns);

  perform mc.prof('2 violations + kicks');
  -- 3. teleport confirmations clear the "awaiting" state
  update mc.player p set awaiting_teleport = null
    from (select conn_id, proto.varint_safe(body, 0) as tid from mc.play_in_work where packet_id = i_tp) a
   where p.conn_id = a.conn_id and p.awaiting_teleport = a.tid;

  perform mc.prof('3 teleport confirmations');
  -- 4. the last position, last rotation and last on-ground flag of each connection (players awaiting a teleport are ignored, like vanilla)
  analyze _mv;
  insert into _fin
  with lp as (select distinct on (conn_id) conn_id, x, y, z from _mv where kind in ('p', 'b') order by conn_id, seq desc),
       lr as (select distinct on (conn_id) conn_id, yaw, pitch from _mv where kind in ('b', 'r') order by conn_id, seq desc),
       lf as (select distinct on (conn_id) conn_id, flags from _mv where kind in ('p', 'b', 'r', 's') order by conn_id, seq desc),
       act as (select distinct conn_id from _mv where kind <> 't')
  select p.conn_id, lp.x, lp.y, lp.z, lp.conn_id is not null, lr.yaw, lr.pitch, lr.conn_id is not null, coalesce((lf.flags & 1) = 1, p.on_ground)
    from act join mc.player p on p.conn_id = act.conn_id
    left join lp on lp.conn_id = p.conn_id left join lr on lr.conn_id = p.conn_id left join lf on lf.conn_id = p.conn_id
   where p.awaiting_teleport is null;

  perform mc.prof('4 last position per connection');
  -- 5. moved too quickly: ignore the move, teleport the player back under a new teleport id
  with bad as (
    select p.conn_id, p.x, p.y, p.z, p.yaw, p.pitch, p.teleport_id + 1 as tid
      from _fin f join mc.player p on p.conn_id = f.conn_id
     where f.has_pos and ((f.x - p.x) ^ 2 + (f.y - p.y) ^ 2 + (f.z - p.z) ^ 2) > 100),
  upd as (update mc.player p set teleport_id = bad.tid, awaiting_teleport = bad.tid from bad where p.conn_id = bad.conn_id returning p.conn_id),
  outq as (insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_player_position(tid, x, y, z, 0, 0, 0, yaw, pitch, 0) from bad returning 1)
  select count(*)::int into corrected from upd;
  delete from _fin where conn_id in (select p.conn_id from mc.player p where p.awaiting_teleport is not null);

  perform mc.prof('5 moved-too-quickly check');
  -- 6. apply (coordinates clamped like vanilla: x,z to +-3.0E7, y to +-2.0E7; pitch to +-90)
  update mc.player p set
      x = case when f.has_pos then greatest(-3.0e7, least(3.0e7, f.x)) else p.x end,
      y = case when f.has_pos then greatest(-2.0e7, least(2.0e7, f.y)) else p.y end,
      z = case when f.has_pos then greatest(-3.0e7, least(3.0e7, f.z)) else p.z end,
      yaw = case when f.has_rot then f.yaw else p.yaw end,
      pitch = case when f.has_rot then greatest(-90, least(90, f.pitch)) else p.pitch end,
      on_ground = f.on_ground,
      chunk_x = case when f.has_pos then floor(greatest(-3.0e7, least(3.0e7, f.x)) / 16)::int else p.chunk_x end,
      chunk_z = case when f.has_pos then floor(greatest(-3.0e7, least(3.0e7, f.z)) / 16)::int else p.chunk_z end,
      vis_dirty = p.vis_dirty or (f.has_pos and (floor(f.x / 16)::int <> p.chunk_x or floor(f.z / 16)::int <> p.chunk_z))
    from _fin f where p.conn_id = f.conn_id;

  perform mc.prof('6 apply to mc.player');
  -- 7. tell the viewers.  The packet per mover is built once, then fanned out and concatenated per viewer connection.
  -- MATERIALIZED matters: otherwise the packet-building expressions are inlined into the fan-out join and evaluated once per viewer instead of once per mover
  -- (measured: 5.8 s per tick for 500 players before, see docs/GAME.md)
  with mv as materialized (
    select entity_id as eid, x, y, z, yaw, pitch, on_ground,
           mc.quant(x) - sent_qx as dx, mc.quant(y) - sent_qy as dy, mc.quant(z) - sent_qz as dz,
           (yaw <> sent_yaw or pitch <> sent_pitch) as rot_changed, greatest(cur_tick - last_sent_tick, 1)::int as ticks
      from mc.player
     where conn_id is not null and (mc.quant(x) <> sent_qx or mc.quant(y) <> sent_qy or mc.quant(z) <> sent_qz or yaw <> sent_yaw or pitch <> sent_pitch)),
  -- Frames are assembled inline from the packet ids looked up once per call (c_*), not through the mc.pkt_* builders: each builder call is a separate
  -- function execution with its own packet-id lookup (72 us per mover measured).  The bytes are the same as mc.pkt_move_entity_pos / _pos_rot / _rot /
  -- mc.pkt_rotate_head (the tests compare them); only the teleport fallback, which is rare, still uses the builder.
  pk as materialized (
    select mv.eid,
      (case when abs(dx) > 32767 or abs(dy) > 32767 or abs(dz) > 32767 then mc.pkt_teleport_entity(mv.eid, x, y, z, 0, 0, 0, yaw, pitch, on_ground)
            else proto.varint(octet_length(q.b) + 1) || set_byte('\x00'::bytea, 0, q.id) || q.b end)
      || case when rot_changed then proto.varint(octet_length(h.b) + 1) || set_byte('\x00'::bytea, 0, c_head) || h.b else '\x'::bytea end as data
    from mv
    cross join lateral (select
        case when (dx, dy, dz) <> (0, 0, 0) then case when rot_changed then c_pr else c_pos end else c_rot end as id,
        case when (dx, dy, dz) <> (0, 0, 0)
             then proto.varint(mv.eid) || set_byte('\x00'::bytea, 0, (case when on_ground then 1 else 0 end) | 2) || proto.varint(ticks)
                  || proto.i16(dx::int) || proto.i16(dy::int) || proto.i16(dz::int)
                  || case when rot_changed then set_byte('\x00'::bytea, 0, mc.angle_byte(yaw)) || set_byte('\x00'::bytea, 0, mc.angle_byte(pitch)) else '\x'::bytea end
             else proto.varint(mv.eid) || proto.bool(on_ground) || set_byte('\x00'::bytea, 0, mc.angle_byte(yaw)) || set_byte('\x00'::bytea, 0, mc.angle_byte(pitch)) end as b) q
    cross join lateral (select proto.varint(mv.eid) || set_byte('\x00'::bytea, 0, mc.angle_byte(yaw)) as b) h),
  upd as (
    update mc.player p set sent_qx = mc.quant(p.x), sent_qy = mc.quant(p.y), sent_qz = mc.quant(p.z), sent_yaw = p.yaw, sent_pitch = p.pitch, last_sent_tick = cur_tick
      from mv where p.entity_id = mv.eid returning p.entity_id),
  outq as (
    insert into mc.play_out (conn_id, data)
    select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from mc.visible v join pk on pk.eid = v.target_eid group by v.viewer_conn
    returning 1)
  select count(*)::int into moved from upd;

  perform mc.prof('7 broadcast to viewers');
  delete from mc.play_in_work where packet_id in (i_pos, i_pr, i_rot, i_st, i_te, i_tp);
  return next;
end $$;
create or replace function mc.apply_player_moves(cur_tick bigint) returns table(moved int, corrected int, kicked int) language plpgsql as $$
declare
  i_pos int := mc.sid('move_player_pos'); i_pr int := mc.sid('move_player_pos_rot'); i_rot int := mc.sid('move_player_rot');
  i_st int := mc.sid('move_player_status_only'); i_te int := mc.sid('client_tick_end'); i_tp int := mc.sid('accept_teleportation');
  c_pos int := mc.pid('move_entity_pos'); c_pr int := mc.pid('move_entity_pos_rot'); c_rot int := mc.pid('move_entity_rot'); c_head int := mc.pid('rotate_head');
  slow boolean; kicked_conns int[];
begin
  select coalesce(count(*) filter (where m.packet_id in (i_pos, i_pr)) <> count(distinct m.conn_id) filter (where m.packet_id in (i_pos, i_pr)), false)
         or coalesce(bool_or((m.packet_id = i_pos and length(m.body) <> 25) or (m.packet_id = i_pr and length(m.body) <> 33)
                             or (m.packet_id = i_rot and length(m.body) <> 9) or (m.packet_id = i_st and length(m.body) <> 1)), false)
    into slow from mc.play_in_work m where m.packet_id in (i_pos, i_pr, i_rot, i_st);
  if slow then
    return query select * from mc.apply_player_moves_general(cur_tick);
    return;
  end if;

  create temp table if not exists _fin2 (conn_id int, x float8, y float8, z float8, has_pos boolean, yaw real, pitch real, has_rot boolean, on_ground boolean, bad boolean) on commit preserve rows;
  delete from _fin2;
  -- 1. the last position, rotation and on-ground flag of each connection that sent movement input; bad = a NaN/infinite value in any of its packets
  insert into _fin2
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
      from mc.play_in_work m where m.packet_id in (i_pos, i_pr, i_rot, i_st)),
  lp as (select distinct on (conn_id) conn_id, x, y, z from d where kind in ('p', 'b') order by conn_id, seq desc),
  lr as (select distinct on (conn_id) conn_id, yaw, pitch from d where kind in ('b', 'r') order by conn_id, seq desc),
  lf as (select distinct on (conn_id) conn_id, flags from d order by conn_id, seq desc),
  nb as (select conn_id from d where x in ('NaN', 'Infinity', '-Infinity') or y in ('NaN', 'Infinity', '-Infinity') or z in ('NaN', 'Infinity', '-Infinity')
                                  or yaw in ('NaN', 'Infinity', '-Infinity') or pitch in ('NaN', 'Infinity', '-Infinity') group by conn_id)
  select lf.conn_id, lp.x, lp.y, lp.z, lp.conn_id is not null, lr.yaw, lr.pitch, lr.conn_id is not null, (lf.flags & 1) = 1, nb.conn_id is not null
    from lf left join lp on lp.conn_id = lf.conn_id left join lr on lr.conn_id = lf.conn_id left join nb on nb.conn_id = lf.conn_id;

  -- 2. rule violation: NaN / infinite values disconnect the player and ignore its input
  select coalesce(array_agg(conn_id), '{}') into kicked_conns from _fin2 where bad;
  kicked := coalesce(array_length(kicked_conns, 1), 0);
  if kicked > 0 then
    perform mc.kick(c, 'multiplayer.disconnect.invalid_player_movement') from unnest(kicked_conns) c;
    delete from _fin2 where bad;
  end if;

  -- 3. teleport confirmations clear the "awaiting" state
  update mc.player p set awaiting_teleport = null
    from (select conn_id, proto.varint_safe(body, 0) as tid from mc.play_in_work where packet_id = i_tp) a
   where p.conn_id = a.conn_id and p.awaiting_teleport = a.tid;

  -- 4. players still waiting for a teleport confirmation are ignored (like vanilla); moved too quickly: ignore the move, teleport back under a new id
  delete from _fin2 f using mc.player p where p.conn_id = f.conn_id and p.awaiting_teleport is not null;
  with bad as (
    select p.conn_id, p.x, p.y, p.z, p.yaw, p.pitch, p.teleport_id + 1 as tid
      from _fin2 f join mc.player p on p.conn_id = f.conn_id
     where f.has_pos and ((f.x - p.x) ^ 2 + (f.y - p.y) ^ 2 + (f.z - p.z) ^ 2) > 100),
  upd as (update mc.player p set teleport_id = bad.tid, awaiting_teleport = bad.tid from bad where p.conn_id = bad.conn_id returning p.conn_id),
  outq as (insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_player_position(tid, x, y, z, 0, 0, 0, yaw, pitch, 0) from bad returning 1)
  select count(*)::int into corrected from upd;
  if corrected > 0 then delete from _fin2 f using mc.player p where p.conn_id = f.conn_id and p.awaiting_teleport is not null; end if;

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
      from mc.player p left join _fin2 f on f.conn_id = p.conn_id
     where p.conn_id is not null),
  mv as materialized (
    select nv.*, mc.quant(nx) - sent_qx as dx, mc.quant(ny) - sent_qy as dy, mc.quant(nz) - sent_qz as dz,
           (nyaw <> sent_yaw or npitch <> sent_pitch) as rot_changed, greatest(cur_tick - last_sent_tick, 1)::int as ticks
      from nv
     where mc.quant(nx) <> sent_qx or mc.quant(ny) <> sent_qy or mc.quant(nz) <> sent_qz or nyaw <> sent_yaw or npitch <> sent_pitch),
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

  delete from mc.play_in_work where packet_id in (i_pos, i_pr, i_rot, i_st, i_te, i_tp);
  return next;
end $$;
