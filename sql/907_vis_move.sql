-- Player visibility, part 8: how other players see a player move.  ServerEntity.sendChanges (26.3, javap -c) for a player, ported:
--   * EntityType.PLAYER has updateInterval 2: the movement part of sendChanges runs on every second call (tickCount % 2 = 0), each ServerEntity counting from its own creation,
--     so the phase is the player's age: tick - trk_start (sql/900).  A step's `ticks` is the number of calls since the last run (2), except on the first run (a linear packet).
--   * the position counts as changed when it is at least 0.00276 blocks (squared distance >= 7.62939453125E-6) from the exact position last sent (VecDeltaCodec.base), and a
--     refresh is sent anyway when tickCount % 60 = 0 (a zero move every 3 seconds)
--   * ServerEntity.createMovePacket: a full position sync (entity_position_sync) instead of a delta when the on-ground flag differs from the one last sent, after 400 runs without
--     one, or when a delta does not fit in a short (more than 8 blocks); otherwise move_entity_pos / move_entity_pos_rot (position changed) or move_entity_rot (only the
--     rotation changed: the packed yaw or pitch byte differs); nothing when neither changed
--   * rotate_head when the packed head yaw differs from the last one sent; the head follows the yaw one tick later (the entity phase copies it)
-- Recorded from the real server in tests/e2e/vis_probe.py, scenario walk.  The classic broadcast (sql/431, dbcraft.vanilla-tracker = false) sends a packet on every second tick
-- from the first change on, with the delta since the last one.

-- add_entity with the angles as the packed bytes the tracker last sent (ServerEntity.lastSentYRot / XRot / YHeadRot) and the exact position (VecDeltaCodec.base)
create or replace function mc.pkt_add_player_entity_b(entity_id int, p_uuid uuid, x float8, y float8, z float8, yb int, pb int, hb int) returns bytea language sql stable parallel safe as $$
  select mc.cb('add_entity', proto.varint(entity_id) || proto.uuid(p_uuid) || proto.varint(mc.entity_type_id('minecraft:player'))
       || proto.f64(x) || proto.f64(y) || proto.f64(z) || '\x00'::bytea
       || proto.i8(pb) || proto.i8(yb) || proto.i8(hb) || proto.varint(0)) $$;

create or replace function mc.pkt_position_sync(p_eid int, p_x float8, p_y float8, p_z float8, p_stepped boolean, p_ticks int, p_yaw real, p_pitch real, p_ground boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('entity_position_sync', proto.varint(p_eid) || (case when p_stepped then '\x0101'::bytea || proto.f64(p_x) || proto.f64(p_y) || proto.f64(p_z) || proto.varint(p_ticks)
                                                                     else '\x00'::bytea || proto.f64(p_x) || proto.f64(p_y) || proto.f64(p_z) end)
                                      || proto.f32(p_yaw) || proto.f32(p_pitch) || proto.bool(p_ground)) $$;

create or replace function mc.vis_move(p_cur bigint) returns void language plpgsql as $$
declare i_pos int := mc.pid('move_entity_pos'); i_pr int := mc.pid('move_entity_pos_rot'); i_rot int := mc.pid('move_entity_rot'); i_head int := mc.pid('rotate_head');
        e int[]; d bytea[];
begin
  with tr as materialized (
    select p.entity_id as eid, p.x, p.y, p.z, p.yaw, p.pitch, p_cur - p.trk_start as tc, p.base_x, p.base_y, p.base_z, p.sent_yb, p.sent_pb, p.sent_hb, p.trk_sync, p.trk_ground,
           case when coalesce((p.wp_state & 2) = 2, false) then false                                           -- a spectator is never on the ground (Player.tick, so from the entity phase of the tick it became one)
                when p.fresh_join and p_cur - p.trk_start < 1 then false else p.on_ground end as og,        -- a first-time player is not on the ground yet when it is created
           mc.angle_byte(p.yaw) as yb, mc.angle_byte(p.pitch) as pb, mc.angle_byte(p.head_yaw) as hb
      from mc.player p where p.conn_id is not null and p.trk_start is not null and p_cur >= p.trk_start and (p_cur - p.trk_start) % 2 = 0
       -- only a player something can happen to: the cheap tests of the conditions below (a position or an angle byte that differs from what was sent, the 60-tick refresh, a ground flag that
       -- differs, a spectator, a first-time player, the 400-body sync); everybody else produces nothing and is not updated, so an idle crowd costs one comparison per player
       and ((p_cur - p.trk_start) % 60 = 0 or p.base_x is null or p.sent_yb is null or p.sent_pb is null or p.sent_hb is null
            or (p.x - p.base_x) ^ 2 + (p.y - p.base_y) ^ 2 + (p.z - p.base_z) ^ 2 >= 7.62939453125E-6
            or mc.angle_byte(p.yaw) <> p.sent_yb or mc.angle_byte(p.pitch) <> p.sent_pb or mc.angle_byte(p.head_yaw) <> p.sent_hb
            or p.trk_ground is distinct from p.on_ground or coalesce((p.wp_state & 2) = 2, false) or p.fresh_join or (p_cur - p.trk_start - p.trk_sync) / 2 > 400)),
  a as materialized (
    select tr.*, ((x - base_x) ^ 2 + (y - base_y) ^ 2 + (z - base_z) ^ 2 >= 7.62939453125E-6) as pos_changed, (yb <> sent_yb or pb <> sent_pb) as rot_changed,
           mc.quant(x) - mc.quant(base_x) as dx, mc.quant(y) - mc.quant(base_y) as dy, mc.quant(z) - mc.quant(base_z) as dz, (tc - trk_sync) / 2 as tp1, trk_ground is distinct from og as gdiff
      from tr),
  b as materialized (
    select a.*, (gdiff or tp1 > 400) as sync1, (pos_changed or tc % 60 = 0) as forced,
           (dx not between -32768 and 32767 or dy not between -32768 and 32767 or dz not between -32768 and 32767) as too_big
      from a),
  c as materialized (
    select b.*, case when sync1 then 1 when forced and too_big then 1 when forced then case when rot_changed then 3 else 2 end when rot_changed then 4 else 0 end as kind from b),
  pk as materialized (
    select c.eid, c.kind, c.sync1, c.og, c.yb, c.pb, c.hb, c.x, c.y, c.z, c.yaw, c.pitch, c.tc, c.sent_hb,
           case c.kind
             when 1 then mc.pkt_position_sync(c.eid, c.x, c.y, c.z, c.tc >= 2, 2, c.yaw, c.pitch, c.og)
             when 2 then mc.cb('move_entity_pos', proto.varint(c.eid) || proto.varint((case when c.og then 1 else 0 end) | (case when c.tc >= 2 then 2 else 0 end))
                                || case when c.tc >= 2 then proto.varint(2) else '\x'::bytea end || proto.i16(c.dx::int) || proto.i16(c.dy::int) || proto.i16(c.dz::int))
             when 3 then mc.cb('move_entity_pos_rot', proto.varint(c.eid) || proto.varint((case when c.og then 1 else 0 end) | (case when c.tc >= 2 then 2 else 0 end))
                                || case when c.tc >= 2 then proto.varint(2) else '\x'::bytea end || proto.i16(c.dx::int) || proto.i16(c.dy::int) || proto.i16(c.dz::int)
                                || proto.i8(c.yb) || proto.i8(c.pb))
             when 4 then mc.cb('move_entity_rot', proto.varint(c.eid) || proto.bool(c.og) || proto.i8(c.yb) || proto.i8(c.pb))
             else '\x'::bytea end
           || case when c.hb <> c.sent_hb then mc.cb('rotate_head', proto.varint(c.eid) || proto.i8(c.hb)) else '\x'::bytea end as data
      from c),
  u as (
    update mc.player p set
        trk_sync = case when pk.sync1 then pk.tc else p.trk_sync end, trk_ground = case when pk.sync1 then pk.og else p.trk_ground end,
        base_x = case when pk.kind in (1, 2, 3) then pk.x else p.base_x end, base_y = case when pk.kind in (1, 2, 3) then pk.y else p.base_y end, base_z = case when pk.kind in (1, 2, 3) then pk.z else p.base_z end,
        sent_qx = case when pk.kind in (1, 2, 3) then mc.quant(pk.x) else p.sent_qx end, sent_qy = case when pk.kind in (1, 2, 3) then mc.quant(pk.y) else p.sent_qy end,
        sent_qz = case when pk.kind in (1, 2, 3) then mc.quant(pk.z) else p.sent_qz end,
        sent_yb = case when pk.kind in (1, 3, 4) then pk.yb else p.sent_yb end, sent_pb = case when pk.kind in (1, 3, 4) then pk.pb else p.sent_pb end,
        sent_yaw = case when pk.kind in (1, 3, 4) then pk.yaw else p.sent_yaw end, sent_pitch = case when pk.kind in (1, 3, 4) then pk.pitch else p.sent_pitch end,
        sent_hb = pk.hb, last_sent_tick = case when pk.kind <> 0 then p_cur else p.last_sent_tick end
      from pk where p.entity_id = pk.eid
       and (pk.sync1 or pk.kind <> 0 or pk.hb <> p.sent_hb)
    returning 1)
  select array_agg(pk.eid order by pk.eid) filter (where octet_length(pk.data) > 0), array_agg(pk.data order by pk.eid) filter (where octet_length(pk.data) > 0) into e, d from pk;
  if e is not null then
    insert into mc.play_out (conn_id, data)
    select v.viewer_conn, string_agg(t.data, '\x'::bytea order by t.eid)
      from mc.visible v join unnest(e, d) as t(eid, data) on t.eid = v.target_eid
     group by v.viewer_conn;
  end if;
end $$;

-- ServerPlayer's head follows the yaw one tick later: the entity phase copies it
create or replace function mc.vis_head(p_cur bigint) returns void language sql as $$
  update mc.player set head_yaw = yaw where conn_id is not null and head_yaw is distinct from yaw $$;

-- The first tracker pass of a new entity (a join, a respawn): besides the pairing bundle the viewers get what became dirty while the entity was created -- its health (and
-- the skin layers, main arm and score when they are not the defaults) as a second set_entity_data, and for a returning player its attributes (all of them are dirty after a load).
-- A first-time player has no attribute instances yet: they follow two ticks later (sql/905, attr_due).  Sent to the viewers only (the joiner got them in its entry burst).
create or replace function mc.vis_first_tick(p_cur bigint) returns void language plpgsql as $$
declare e int[]; d bytea[];
begin
  if not exists (select 1 from mc.player where trk_first and conn_id is not null) then return; end if;
  with f as (
    select p.* from mc.player p where p.trk_first and p.conn_id is not null and p_cur >= p.trk_start order by p.entity_id),
  pk as (
    select f.entity_id as eid,
           case when (mc.ed_nondefault_mask(f) & 120) <> 0
                then mc.pkt_entity_data(f.entity_id, mc.ed_entries(0, 0, 0, f.health, f.main_hand, f.skin_parts, f.xp_score, mc.ed_nondefault_mask(f) & 120)) else '\x'::bytea end
           || case when not f.fresh_join and a.ents is not null then mc.pkt_update_attributes(f.entity_id, a.ents) else '\x'::bytea end as data
      from f left join lateral (select array_agg(decode(x.entry, 'hex') order by x.id) as ents from mc.attr_now(f.uuid, f.held_slot, f.gamemode, f.sprinting, f.attr_seen) x) a on true),
  u as (update mc.player p set trk_first = false from f where p.entity_id = f.entity_id returning 1)
  select array_agg(pk.eid order by pk.eid) filter (where octet_length(pk.data) > 0), array_agg(pk.data order by pk.eid) filter (where octet_length(pk.data) > 0) into e, d from pk;
  if e is not null then perform mc.send_players_and_viewers(e, d, false); end if;
end $$;
