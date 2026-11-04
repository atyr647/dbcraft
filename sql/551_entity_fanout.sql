-- Fan-out per chunk cell for the lane mobs (PERF-ENTITY.md, "Part 2").  The packets of the mobs that are due in one cell and tracking range are concatenated ONCE into a blob
-- and every viewer of the cell receives the blob; viewers are probed in the interest relation once per cell, and the second probe (the tracking-range check against the
-- viewer's cell) is skipped when the tracking range is at least the view distance, because then every viewer of the cell is in range by construction.
-- The set of packets a viewer receives is unchanged; their order inside the viewer's row changes from "by entity id" to "by cell, then entity id" (tests/sql/551 compares the
-- multisets and the reconstruction of the viewer state).  Vanilla ranges and intervals were re-read from the 26.3 bytecode for this (cow 10 / zombie 8 / item 6 chunks;
-- update interval 3 by default, 20 for items): they are what mc.entity_type_param holds.

create or replace function mc.entity_lane_step(p_tick bigint) returns int[] language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off as $$
declare due int[]; sync_ids int[]; auto_ids int[] := '{}'; vr int := mc.prop_int('view-distance');
begin
    if mc.entity_auto_enabled() then auto_ids := mc.entity_auto_tick(p_tick); end if;           -- the autonomous lanes (sql/940): one statement, returns the ids the generic tracker must take
    select coalesce(array_agg(l.id), '{}') into due from mc.entity_lane l where not l.auto and l.slot = (p_tick % l.every)::int and l.goal_until > p_tick;
    if cardinality(due) = 0 then return auto_ids; end if;
    with cur as materialized (
        select e.id, e.cx, e.cz, e.y, e.yaw, e.pitch, e.on_ground, p.tracking_chunks as trk, (p_tick - e.born_tick) as tc,
               e.x + e.gx * (p_tick - e.phys_tick) as nx, e.z + e.gz * (p_tick - e.phys_tick) as nz,
               l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick
          from unnest(due) d(id)
          cross join lateral (select e0.* from mc.entity e0 where e0.id = d.id offset 0) e      -- offset 0: one primary-key probe per due mob (with statistics from before the lanes existed the planner
          join mc.entity_lane l on l.id = d.id                                                   -- estimated one matching row and scanned the whole entity table once per due id: 5 ms of 13)
          join mc.entity_type_param p on p.type = e.type
         where e.lane_until > p_tick and e.phys_tick < p_tick
    ), calc as materialized (
        select q.*, (q.dx * q.dx + q.dy * q.dy + q.dz * q.dz >= 128 or q.tc % 60 = 0) as pos_ch,
               (abs(mc.angle_byte(q.yaw) - mc.angle_byte(q.syaw)) >= 1) as rot_ch,
               (abs(q.dx) > 32767 or abs(q.dy) > 32767 or abs(q.dz) > 32767 or q.tc % 400 = 0) as sync
          from (select cur.*, mc.quant(cur.nx) as qx, mc.quant(cur.y) as qy, mc.quant(cur.nz) as qz,
                       mc.quant(cur.nx) - cur.sqx as dx, mc.quant(cur.y) - cur.sqy as dy, mc.quant(cur.nz) - cur.sqz as dz from cur) q
    ), pk as materialized (
        select c.id, c.cx, c.cz, c.trk,
               case when c.pos_ch then mc.epkt_mob_move(c.id, c.dx::int, c.dy::int, c.dz::int, (p_tick - c.last_tick)::int, c.on_ground, c.rot_ch, c.yaw, c.pitch)
                    else mc.pkt_move_entity_rot(c.id, c.yaw, c.pitch, c.on_ground) || mc.pkt_rotate_head(c.id, c.yaw) end as pkt
          from calc c where not c.sync and (c.pos_ch or c.rot_ch)
    ), cellblob as materialized (
        -- ONE blob per (chunk cell, tracking range): the packets of all due mobs in the cell, in id order.  Every viewer of the cell gets the blob once
        -- instead of every packet once (docs/PERF-ENTITY.md, "fan-out per cell"; the same idea as mc.fanout_moves of sql/430 for players).
        select pk.cx, pk.cz, pk.trk, string_agg(pk.pkt, '\x'::bytea order by pk.id) as blob from pk group by pk.cx, pk.cz, pk.trk
    ), fan as (
        insert into mc.play_out (conn_id, data)
        select q.conn_id, string_agg(q.blob, '\x'::bytea)
          from (
                -- tracking range at least the view distance: every viewer of the cell is in range, no second probe (the common case: cows 10, items 6 are the rare ones)
                select v.conn_id, cb.cx, cb.cz, cb.trk, cb.blob
                  from cellblob cb cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = cb.cx and vv.cz = cb.cz offset 0) v
                 where cb.trk >= vr
                union all
                select v.conn_id, cb.cx, cb.cz, cb.trk, cb.blob
                  from cellblob cb cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = cb.cx and vv.cz = cb.cz offset 0) v
                  join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - cb.cx), abs(vc.cz - cb.cz)) <= cb.trk
                 where cb.trk < vr) q
         group by q.conn_id order by q.conn_id returning 1
    ), ul as (
        update mc.entity_lane l set sqx = case when c.pos_ch then c.qx else l.sqx end, sqy = case when c.pos_ch then c.qy else l.sqy end,
               sqz = case when c.pos_ch then c.qz else l.sqz end, syaw = case when c.rot_ch then c.yaw else l.syaw end,
               last_tick = case when c.pos_ch then p_tick else l.last_tick end
          from calc c where l.id = c.id and not c.sync returning l.id
    ), dl as (
        delete from mc.entity_lane l using calc c where l.id = c.id and c.sync returning l.id
    ), ue as (
        -- the entity row is NOT rewritten while the lane lasts (x, z, phys_tick, gx, gz fix the position for the whole lane; mc.entity_live gives it); only a position sync
        -- ends the lane and brings the row up to date for the generic tracker
        update mc.entity e set x = c.nx, z = c.nz, phys_tick = p_tick, lane_until = 0,
               sent_qx = c.sqx, sent_qy = c.sqy, sent_qz = c.sqz, sent_yaw = c.syaw, last_sent_tick = c.last_tick
          from calc c where e.id = c.id and c.sync returning e.id, c.sync
    )
    select coalesce(array_agg(ue.id), '{}') into sync_ids from ue;
    return auto_ids || sync_ids;
end $$;

-- (b) the tracker for entities outside lanes (sql/542's) with one change: the remove_entities packet of an entity that changed chunk is built once per entity and joined, not built
-- inside the per-(entity, viewer) anti-join: 500 crowded viewers x 3 border crossers = 1,500 builds of 27 us each = 40 ms of a tick.  Same bytes (tests/sql/542 and 551).
create or replace function mc.entity_tracker(p_tick bigint, p_ids int[]) returns int language plpgsql volatile as $$
declare n1 int := 0; n2 int := 0;
begin
    -- 1. new entities: appear for everybody who can see their cell; their sent-state base is where they are now (one probe of the partial index: usually there are none)
    if exists (select 1 from mc.entity e where e.last_sent_tick = 0) then
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
    end if;

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
                   case when (f.cx, f.cz) <> (f.sent_cx, f.sent_cz) then mc.epkt_appear(f.id, f.uuid, f.type, f.type_id, f.x, f.y, f.z, f.vx, f.vy, f.vz, f.yaw, f.pitch, f.data) end as appear,     -- only for entities that changed chunk
                   case when (f.cx, f.cz) <> (f.sent_cx, f.sent_cz) then mc.pkt_remove_entities(array[f.id]) end as rmpkt      -- built ONCE per entity, not once per (entity, viewer) pair: in a crowd 1,500 pairs cost 40 ms
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
                select vo.conn_id, vo.id, pk.rmpkt from vo join pk on pk.id = vo.id
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

-- (c) despawn (sql/520's): the "no viewer in the cell" test of mobs probes the interest relation per mob (offset 0) instead of letting the planner hash all of it (every 20th tick, 36 ms at 500 players).
create or replace function mc.entity_despawn(p_tick bigint) returns int language plpgsql volatile as $$
declare ids int[];
begin
    if p_tick % 20 <> 0 then return 0; end if;
    select array_agg(e.id) into ids
      from mc.entity e join mc.entity_type_param p on p.type = e.type
     where (p.max_age is not null and p_tick - e.born_tick >= p.max_age)
        or e.y < -128
        or (p.kind = 'mob' and p_tick - e.born_tick > 600 and not exists (select 1 from mc.entity_cell_viewer v where v.cx = e.cx and v.cz = e.cz offset 0));      -- offset 0: one index probe per mob; without it the planner hashes the whole interest relation (220,000 rows at 500 players: 77 ms)
    if ids is null then return 0; end if;
    return mc.entity_discard(ids);
end $$;
