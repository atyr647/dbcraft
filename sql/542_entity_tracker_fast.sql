-- Entity tracker, fast mob packets.  Same logic as sql/530's mc.entity_tracker, with ONE change: the movement packet of a mob (stepped delta, no position sync) is built by
-- mc.epkt_mob_move, a single function that writes the bytes directly, instead of a chain of about ten small function calls per packet (measured: the packet-building stage was
-- more than half of the tracker's time).  mc.epkt_mob_move returns exactly what the chain returned (tests/sql/542 compares them on random inputs, byte for byte).

-- move_entity_pos / move_entity_pos_rot (+ rotate_head when the rotation changed) of a mob: [len][id][entity VarInt][flags][ticks VarInt][dx dy dz shorts]([yaw][pitch])
-- followed by [len][head id][entity VarInt][yaw] when the rotation changed.  Anything outside the small-number ranges the fast path assumes (entity id >= 2^21, ticks >= 2^14,
-- packet ids >= 128) falls back to the generic builders.
create or replace function mc.epkt_mob_move(p_eid int, dx int, dy int, dz int, p_ticks int, og boolean, rot boolean, yaw real, pitch real)
returns bytea language plpgsql stable parallel safe as $$
declare b bytea := '\x00000000000000000000000000000000000000000000000000000000'::bytea; i int := 0; n1 int; n2 int; l int; pid int; hid int := mc.pid('rotate_head');
        ya int; pa int;
begin
    pid := case when rot then mc.pid('move_entity_pos_rot') else mc.pid('move_entity_pos') end;
    if p_eid >= 2097152 or p_eid < 0 or p_ticks >= 16384 or p_ticks < 0 or pid >= 128 or hid >= 128 then
        return case when rot then mc.pkt_move_entity_pos_rot(p_eid, dx, dy, dz, p_ticks, yaw, pitch, og) || mc.pkt_rotate_head(p_eid, yaw)
                    else mc.pkt_move_entity_pos(p_eid, dx, dy, dz, p_ticks, og) end;
    end if;
    n1 := case when p_eid < 128 then 1 when p_eid < 16384 then 2 else 3 end;
    n2 := case when p_ticks < 128 then 1 else 2 end;
    ya := (floor((yaw * 256::real) / 360::real)::int) & 255;
    l := n1 + 1 + n2 + 6 + case when rot then 2 else 0 end;                     -- body length: entity, flags, ticks, three shorts, (yaw, pitch)
    b := set_byte(b, i, l + 1); i := i + 1;                                     -- frame length: id + body (one byte: below 128 by construction: l <= 14)
    b := set_byte(b, i, pid); i := i + 1;
    -- entity VarInt
    if n1 = 1 then b := set_byte(b, i, p_eid); i := i + 1;
    elsif n1 = 2 then b := set_byte(b, i, (p_eid & 127) | 128); b := set_byte(b, i + 1, p_eid >> 7); i := i + 2;
    else b := set_byte(b, i, (p_eid & 127) | 128); b := set_byte(b, i + 1, ((p_eid >> 7) & 127) | 128); b := set_byte(b, i + 2, p_eid >> 14); i := i + 3; end if;
    b := set_byte(b, i, (case when og then 1 else 0 end) | 2); i := i + 1;       -- flags: bit 0 on ground, bit 1: one step
    if n2 = 1 then b := set_byte(b, i, p_ticks); i := i + 1;
    else b := set_byte(b, i, (p_ticks & 127) | 128); b := set_byte(b, i + 1, p_ticks >> 7); i := i + 2; end if;
    b := set_byte(b, i, (dx >> 8) & 255); b := set_byte(b, i + 1, dx & 255);
    b := set_byte(b, i + 2, (dy >> 8) & 255); b := set_byte(b, i + 3, dy & 255);
    b := set_byte(b, i + 4, (dz >> 8) & 255); b := set_byte(b, i + 5, dz & 255); i := i + 6;
    if rot then
        pa := (floor((pitch * 256::real) / 360::real)::int) & 255;
        b := set_byte(b, i, ya); b := set_byte(b, i + 1, pa); i := i + 2;
        -- rotate_head: [len][id][entity VarInt][yaw]
        b := set_byte(b, i, n1 + 2); i := i + 1;
        b := set_byte(b, i, hid); i := i + 1;
        if n1 = 1 then b := set_byte(b, i, p_eid); i := i + 1;
        elsif n1 = 2 then b := set_byte(b, i, (p_eid & 127) | 128); b := set_byte(b, i + 1, p_eid >> 7); i := i + 2;
        else b := set_byte(b, i, (p_eid & 127) | 128); b := set_byte(b, i + 1, ((p_eid >> 7) & 127) | 128); b := set_byte(b, i + 2, p_eid >> 14); i := i + 3; end if;
        b := set_byte(b, i, ya); i := i + 1;
    end if;
    return substring(b from 1 for i);
end $$;

create or replace function mc.entity_tracker(p_tick bigint, p_ids int[]) returns int language plpgsql volatile as $$
declare n1 int := 0; n2 int := 0;
begin
    -- 1. new entities: appear for everybody who can see their cell; their sent-state base is where they are now
    with ne as materialized (
        select e.id, e.cx, e.cz, p.tracking_chunks as trk,
               mc.epkt_appear(e.id, e.uuid, e.type, e.type_id, e.x, e.y, e.z, e.vx, e.vy, e.vz, e.yaw, e.pitch, e.data) as pkt
          from mc.entity e join mc.entity_type_param p on p.type = e.type where e.last_sent_tick = 0
    ), fan as (
        insert into mc.play_out (conn_id, data)
        select v.conn_id, string_agg(ne.pkt, '\x'::bytea order by ne.id)
          from ne cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = ne.cx and vv.cz = ne.cz offset 0) v     -- offset 0: an index probe per entity, not a scan of the whole relation
          join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - ne.cx), abs(vc.cz - ne.cz)) <= ne.trk
         group by v.conn_id order by v.conn_id returning 1
    ), upd as (
        update mc.entity e set last_sent_tick = greatest(p_tick, 1), sent_cx = e.cx, sent_cz = e.cz,
               sent_qx = mc.quant(e.x), sent_qy = mc.quant(e.y), sent_qz = mc.quant(e.z), sent_vx = e.vx, sent_vy = e.vy, sent_vz = e.vz,
               sent_yaw = e.yaw, sent_pitch = e.pitch, sent_on_ground = e.on_ground
          from ne where e.id = ne.id returning e.id
    )
    select (select count(*) from upd) into n1;

    -- 2. movement of the entities processed this tick
    if cardinality(p_ids) > 0 then
        with mv as materialized (
            select e.id, e.uuid, e.type, e.type_id, e.cx, e.cz, e.sent_cx, e.sent_cz, e.x, e.y, e.z, e.vx, e.vy, e.vz, e.yaw, e.pitch, e.on_ground, e.deep_sleep, e.data,
                   e.sent_qx, e.sent_qy, e.sent_qz, e.sent_vx, e.sent_vy, e.sent_vz, e.sent_yaw, e.sent_pitch, e.sent_on_ground, e.last_sent_tick,
                   p.update_interval, p.track_delta, p.linear_delta, p.tracking_chunks as trk, p.kind, (p_tick - e.born_tick) as tc,
                   mc.quant(e.x) as qx, mc.quant(e.y) as qy, mc.quant(e.z) as qz,
                   ((e.vx - e.sent_vx) ^ 2 + (e.vy - e.sent_vy) ^ 2 + (e.vz - e.sent_vz) ^ 2) as vd
              from mc.entity e join mc.entity_type_param p on p.type = e.type
             where e.id = any(p_ids) and e.last_sent_tick > 0
        ), d as materialized (
            select mv.*, mv.qx - mv.sent_qx as dx, mv.qy - mv.sent_qy as dy, mv.qz - mv.sent_qz as dz,
                   mc.angle_byte(mv.yaw) as yb, mc.angle_byte(mv.pitch) as pb, mc.angle_byte(mv.sent_yaw) as syb, mc.angle_byte(mv.sent_pitch) as spb
              from mv
             where mv.tc % mv.update_interval = 0 or mv.cx <> mv.sent_cx or mv.cz <> mv.sent_cz       -- items are looked at every 20 ticks only (as captured): the client extrapolates from the last velocity
                or mv.deep_sleep       -- processed this tick and now asleep: one last look, so the final position and the zero velocity reach the clients
        ), f as materialized (
            select d.*, (d.dx ^ 2 + d.dy ^ 2 + d.dz ^ 2 >= 128 or d.tc % 60 = 0) as pos_ch, (abs(d.yb - d.syb) >= 1 or abs(d.pb - d.spb) >= 1) as rot_ch,
                   (abs(d.dx) > 32767 or abs(d.dy) > 32767 or abs(d.dz) > 32767 or d.tc % 400 = 0
                    or (d.track_delta and (d.dx ^ 2 + d.dy ^ 2 + d.dz ^ 2 >= 128 or d.tc % 60 = 0))) as sync,     -- items: a moved item is sent as entity_position_sync (as captured)
                   (d.track_delta and (d.vd > 1e-7 or (d.vd > 0 and d.vx = 0 and d.vy = 0 and d.vz = 0))) as vel_ch
              from d
        ), pk as materialized (
            select f.id, f.cx, f.cz, f.sent_cx, f.sent_cz, f.trk, f.uuid, f.type, f.type_id, f.x, f.y, f.z, f.vx, f.vy, f.vz, f.yaw, f.pitch, f.data, f.qx, f.qy, f.qz,
                   f.pos_ch, f.rot_ch, f.sync, f.vel_ch,
                   case when f.vel_ch then mc.epkt_motion(f.id, f.vx, f.vy, f.vz) else '\x'::bytea end      -- vanilla sends the velocity first (as captured)
                   || case when f.pos_ch and not f.sync and not f.linear_delta then mc.epkt_mob_move(f.id, f.dx::int, f.dy::int, f.dz::int, (p_tick - f.last_sent_tick)::int, f.on_ground, f.rot_ch, f.yaw, f.pitch)
                        when f.sync then mc.epkt_sync(f.id, f.x, f.y, f.z, f.vx, f.vy, f.vz, f.yaw, f.pitch, f.on_ground)
                        when f.pos_ch and f.rot_ch then case when f.linear_delta then mc.epkt_move_lin_rot(f.id, f.dx::int, f.dy::int, f.dz::int, f.yaw, f.pitch, f.on_ground)
                                                              else mc.pkt_move_entity_pos_rot(f.id, f.dx::int, f.dy::int, f.dz::int, (p_tick - f.last_sent_tick)::int, f.yaw, f.pitch, f.on_ground) end
                        when f.pos_ch then case when f.linear_delta then mc.epkt_move_lin(f.id, f.dx::int, f.dy::int, f.dz::int, f.on_ground)
                                                else mc.pkt_move_entity_pos(f.id, f.dx::int, f.dy::int, f.dz::int, (p_tick - f.last_sent_tick)::int, f.on_ground) end
                        when f.rot_ch then mc.pkt_move_entity_rot(f.id, f.yaw, f.pitch, f.on_ground)
                        else '\x'::bytea end
                   || case when f.kind = 'mob' and f.rot_ch and not (f.pos_ch and not f.sync and not f.linear_delta) then mc.pkt_rotate_head(f.id, f.yaw) else '\x'::bytea end as pkt,
                   case when (f.cx, f.cz) <> (f.sent_cx, f.sent_cz) then mc.epkt_appear(f.id, f.uuid, f.type, f.type_id, f.x, f.y, f.z, f.vx, f.vy, f.vz, f.yaw, f.pitch, f.data) end as appear     -- only for entities that changed chunk
              from f
        ), vn as materialized (       -- viewers of the new cell
            select pk.id, v.conn_id from pk cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = pk.cx and vv.cz = pk.cz offset 0) v
              join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - pk.cx), abs(vc.cz - pk.cz)) <= pk.trk
        ), vo as materialized (       -- viewers of the old cell, only for entities that changed cell
            select pk.id, v.conn_id from pk cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = pk.sent_cx and vv.cz = pk.sent_cz offset 0) v
              join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - pk.sent_cx), abs(vc.cz - pk.sent_cz)) <= pk.trk
             where (pk.cx, pk.cz) <> (pk.sent_cx, pk.sent_cz)
        ), out_ as (
            -- what each viewer gets: movement for those who knew the entity, appearance for those who gain it, removal for those who lose it
            select o.conn_id, o.seq, o.pkt from (
                select vn.conn_id, pk.id as seq, case when pk.cx = pk.sent_cx and pk.cz = pk.sent_cz then pk.pkt
                                                      when exists (select 1 from vo where vo.id = vn.id and vo.conn_id = vn.conn_id) then pk.pkt
                                                      else pk.appear end as pkt
                  from vn join pk on pk.id = vn.id
                union all
                select vo.conn_id, vo.id, mc.pkt_remove_entities(array[vo.id]) from vo
                 where not exists (select 1 from vn where vn.id = vo.id and vn.conn_id = vo.conn_id)
            ) o where octet_length(o.pkt) > 0
        ), fan as (
            insert into mc.play_out (conn_id, data)
            select conn_id, string_agg(pkt, '\x'::bytea order by seq) from out_ group by conn_id order by conn_id returning 1
        ), upd as (
            update mc.entity e set sent_cx = pk.cx, sent_cz = pk.cz,
                   sent_qx = case when pk.pos_ch or pk.sync then pk.qx else e.sent_qx end, sent_qy = case when pk.pos_ch or pk.sync then pk.qy else e.sent_qy end,
                   sent_qz = case when pk.pos_ch or pk.sync then pk.qz else e.sent_qz end,
                   last_sent_tick = case when pk.pos_ch or pk.sync then p_tick else e.last_sent_tick end,
                   sent_vx = case when pk.vel_ch then pk.vx else e.sent_vx end, sent_vy = case when pk.vel_ch then pk.vy else e.sent_vy end, sent_vz = case when pk.vel_ch then pk.vz else e.sent_vz end,
                   sent_yaw = case when pk.rot_ch or pk.sync then pk.yaw else e.sent_yaw end, sent_pitch = case when pk.rot_ch or pk.sync then pk.pitch else e.sent_pitch end
              from pk where e.id = pk.id returning e.id
        )
        select (select count(*) from upd) into n2;
    end if;
    return n1 + n2;
end $$;

