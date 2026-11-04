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

-- The movement step for the players on an even tick of their age that moved in the last two ticks, were woken by an event, or are due for the 60-tick refresh / the sync after 400
-- runs (the test of mc.vis_find, sql/905, which says whether there are any: keep the two in step).  The tracker's state is the narrow mc.vtrk (HOT updates, one statement per tick); mc.player is written only when a position sync changes the
-- ground flag / the sync counter.  The head follows the yaw one tick later: the head of this tick's body is the yaw the player had at the END of the last tick, which is the yaw
-- before this tick's movement packet (mc.player.yaw_prev, set by the movement step) when the player moved this tick, and the current yaw otherwise.
drop function if exists mc.vis_move(bigint, int[]);
drop function if exists mc.vis_head(bigint);
create or replace function mc.vis_move(p_cur bigint) returns void language plpgsql as $$
declare e int[]; d bytea[]; all_mv boolean := coalesce(current_setting('dbcraft.vis_scan_all', true), '') = 'on';       -- (tests: look at everybody)
begin
  with a as materialized (
    select p.entity_id as eid, p.x, p.y, p.z, p.yaw, p.pitch, l1.tc, v.base_x, v.base_y, v.base_z, v.sent_yb, v.sent_pb, v.sent_hb, p.trk_sync, p.trk_ground, l1.og, l1.yb, l1.pb, l1.hb,
           l2.pos_changed, l2.rot_changed, l2.dx, l2.dy, l2.dz, l2.sync1, l2.forced, l2.too_big
      from mc.player p join mc.vtrk v on v.entity_id = p.entity_id
      cross join lateral (select p_cur - p.trk_start as tc,
                                 case when coalesce((p.wp_state & 2) = 2, false) then false                                           -- a spectator is never on the ground (Player.tick, so from the entity phase of the tick it became one)
                                      when p.fresh_join and p_cur - p.trk_start < 1 then false else p.on_ground end as og,        -- a first-time player is not on the ground yet when it is created
                                 mc.angle_byte(p.yaw) as yb, mc.angle_byte(p.pitch) as pb, mc.angle_byte(case when p.last_move_tick = p_cur then p.yaw_prev else p.yaw end) as hb) l1
      cross join lateral (select ((p.x - v.base_x) ^ 2 + (p.y - v.base_y) ^ 2 + (p.z - v.base_z) ^ 2 >= 7.62939453125E-6) as pos_changed, (l1.yb <> v.sent_yb or l1.pb <> v.sent_pb) as rot_changed,
                                 mc.quant(p.x) - mc.quant(v.base_x) as dx, mc.quant(p.y) - mc.quant(v.base_y) as dy, mc.quant(p.z) - mc.quant(v.base_z) as dz,
                                 (p.trk_ground is distinct from l1.og or (l1.tc - p.trk_sync) / 2 > 400) as sync1) l3
      cross join lateral (select l3.sync1, l3.dx, l3.dy, l3.dz,
                                 (((p.x - v.base_x) ^ 2 + (p.y - v.base_y) ^ 2 + (p.z - v.base_z) ^ 2 >= 7.62939453125E-6) or l1.tc % 60 = 0) as forced,
                                 (l3.dx not between -32768 and 32767 or l3.dy not between -32768 and 32767 or l3.dz not between -32768 and 32767) as too_big,
                                 l3.pos_changed, l3.rot_changed) l2
     where p.conn_id is not null and p.trk_start is not null and p_cur >= p.trk_start and (p_cur - p.trk_start) % 2 = 0
       and (all_mv or p.last_move_tick >= p_cur - 1 or (p.last_move_tick = p_cur - 2 and p.yaw_prev is distinct from p.yaw)
            or p.vis_wake >= p_cur or (p_cur - p.trk_start) % 60 = 0 or p_cur - p.trk_start - p.trk_sync >= 802)),
  pk as materialized (
    select a.eid, k.kind, a.sync1, a.og, a.yb, a.pb, a.hb, a.x, a.y, a.z, a.tc, a.sent_hb,
           case k.kind
             when 1 then mc.pkt_position_sync(a.eid, a.x, a.y, a.z, a.tc >= 2, 2, a.yaw, a.pitch, a.og)
             when 2 then mc.cb('move_entity_pos', proto.varint(a.eid) || proto.varint((case when a.og then 1 else 0 end) | (case when a.tc >= 2 then 2 else 0 end))
                                || case when a.tc >= 2 then proto.varint(2) else '\x'::bytea end || proto.i16(a.dx::int) || proto.i16(a.dy::int) || proto.i16(a.dz::int))
             when 3 then mc.cb('move_entity_pos_rot', proto.varint(a.eid) || proto.varint((case when a.og then 1 else 0 end) | (case when a.tc >= 2 then 2 else 0 end))
                                || case when a.tc >= 2 then proto.varint(2) else '\x'::bytea end || proto.i16(a.dx::int) || proto.i16(a.dy::int) || proto.i16(a.dz::int)
                                || proto.i8(a.yb) || proto.i8(a.pb))
             when 4 then mc.cb('move_entity_rot', proto.varint(a.eid) || proto.bool(a.og) || proto.i8(a.yb) || proto.i8(a.pb))
             else '\x'::bytea end
           || case when a.hb <> a.sent_hb then mc.cb('rotate_head', proto.varint(a.eid) || proto.i8(a.hb)) else '\x'::bytea end as data
      from a cross join lateral (select case when a.sync1 then 1 when a.forced and a.too_big then 1 when a.forced then case when a.rot_changed then 3 else 2 end when a.rot_changed then 4 else 0 end as kind) k),
  u as (
    update mc.vtrk v set
        base_x = case when pk.kind in (1, 2, 3) then pk.x else v.base_x end, base_y = case when pk.kind in (1, 2, 3) then pk.y else v.base_y end, base_z = case when pk.kind in (1, 2, 3) then pk.z else v.base_z end,
        sent_yb = case when pk.kind in (1, 3, 4) then pk.yb else v.sent_yb end, sent_pb = case when pk.kind in (1, 3, 4) then pk.pb else v.sent_pb end, sent_hb = pk.hb
      from pk where v.entity_id = pk.eid and (pk.kind <> 0 or pk.hb <> v.sent_hb)
    returning 1),
  sy as (
    update mc.player p set trk_sync = pk.tc, trk_ground = pk.og from pk where p.entity_id = pk.eid and pk.sync1 returning 1)
  select array_agg(pk.eid order by pk.eid) filter (where octet_length(pk.data) > 0), array_agg(pk.data order by pk.eid) filter (where octet_length(pk.data) > 0) into e, d from pk;
  if e is not null then
    insert into mc.play_out (conn_id, data)
    select v.viewer_conn, string_agg(t.data, '\x'::bytea order by t.eid)
      from mc.visible v join unnest(e, d) as t(eid, data) on t.eid = v.target_eid
     group by v.viewer_conn;
  end if;
end $$;

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
