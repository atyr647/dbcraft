-- Entity tracker (prototype): who sees which entity, and the packets they get.  Rules read from ServerEntity.sendChanges (bytecode) and the captured traffic:
--   * an entity is visible to a viewer when the chunk distance (Chebyshev) between the viewer's chunk and the entity's chunk is within min(view distance, tracking range)
--   * every `updateInterval` ticks (items: 20, mobs: 3) (and when the entity changed chunk) check for movement; items are NOT looked at in between (the capture shows 20, 34, 60: vanilla's
--     in-between checks come from an impulse flag this prototype does not model)
--   * a position packet is sent when the quantised (1/4096) delta squared is >= 128 (= 7.62939453125E-6 blocks^2) or every 60 ticks; a rotation packet when an angle byte changed
--   * deltas that do not fit a short, or every 400 ticks: entity_position_sync;  items use the Linear delta form, mobs the Stepped one (as the captured packets do)
--   * set_entity_motion for tracked-delta entities when the velocity changed
-- Packets for one viewer and tick are concatenated into ONE play_out row (the gateway writes bytes anyway), and each packet is built once per entity, not once per viewer.

------------------------------------------------------------------------------------------------ packet builders (layouts: javap + captured packets)
create or replace function mc.epkt_add(eid int, p_uuid uuid, type_id int, x float8, y float8, z float8, vx float8, vy float8, vz float8, yaw real, pitch real, head real, data int default 0)
returns bytea language sql stable parallel safe as $$
  select mc.cb('add_entity', proto.varint(eid) || proto.uuid(p_uuid) || proto.varint(type_id) || proto.f64(x) || proto.f64(y) || proto.f64(z) || proto.lpvec3(vx, vy, vz)
       || proto.i8(mc.angle_byte(pitch)) || proto.i8(mc.angle_byte(yaw)) || proto.i8(mc.angle_byte(head)) || proto.varint(data)) $$;
-- entity data of an item: [index 8][serializer 7 = item stack][count][item id][0 added][0 removed][0xff]   (as captured)
create or replace function mc.epkt_item_data(eid int, item text, cnt int) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_entity_data', proto.varint(eid) || '\x0807'::bytea || proto.varint(cnt) || proto.varint(mc.item_id(item)) || '\x0000ff'::bytea) $$;
create or replace function mc.epkt_motion(eid int, vx float8, vy float8, vz float8) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_entity_motion', proto.varint(eid) || proto.lpvec3(vx, vy, vz)) $$;
-- entity_position_sync: [entity VarInt][delta movement LpVec3][position 3 doubles][yRot f32][xRot f32][on ground]  (verified on the captured ITEM packets; the one captured cow packet did not parse so: unverified for mobs)
create or replace function mc.epkt_sync(eid int, x float8, y float8, z float8, vx float8, vy float8, vz float8, yaw real, pitch real, og boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('entity_position_sync', proto.varint(eid) || proto.lpvec3(vx, vy, vz) || proto.f64(x) || proto.f64(y) || proto.f64(z) || proto.f32(yaw) || proto.f32(pitch) || proto.bool(og)) $$;
-- Linear deltas (items): [entity][flags: bit0 on ground][dx dy dz shorts] (+ [yaw][pitch] bytes for pos_rot)   (as captured)
create or replace function mc.epkt_move_lin(eid int, dx int, dy int, dz int, og boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('move_entity_pos', proto.varint(eid) || proto.varint(case when og then 1 else 0 end) || proto.i16(dx) || proto.i16(dy) || proto.i16(dz)) $$;
create or replace function mc.epkt_move_lin_rot(eid int, dx int, dy int, dz int, yaw real, pitch real, og boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('move_entity_pos_rot', proto.varint(eid) || proto.varint(case when og then 1 else 0 end) || proto.i16(dx) || proto.i16(dy) || proto.i16(dz)
       || proto.i8(mc.angle_byte(yaw)) || proto.i8(mc.angle_byte(pitch))) $$;
-- everything a viewer is sent when an entity appears
create or replace function mc.epkt_appear(eid int, p_uuid uuid, p_type text, type_id int, x float8, y float8, z float8, vx float8, vy float8, vz float8, yaw real, pitch real, p_data jsonb)
returns bytea language sql stable parallel safe as $$
  select mc.epkt_add(eid, p_uuid, type_id, x, y, z, vx, vy, vz, yaw, pitch, yaw, 0)
         || case when p_type = 'minecraft:item' then mc.epkt_item_data(eid, p_data ->> 'item', (p_data ->> 'count')::int) else '\x'::bytea end $$;

------------------------------------------------------------------------------------------------ the interest relation (which chunk cells each player sees)
-- Only players that crossed a chunk border (or joined, or changed the view distance) are touched.  Entities appear in / disappear from their view as cells enter / leave it.
create or replace function mc.entity_viewers_refresh(p_tick bigint) returns int language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off as $$      -- the joins here are a few hundred array rows against tables of 200,000 rows: primary-key probes, never scans
declare vr int := mc.prop_int('view-distance'); cc int[]; ncx int[]; ncz int[]; ocx int[]; ocz int[]; n int := 0;
        rm_conn int[]; rm_cx int[]; rm_cz int[]; rm_ox int[]; rm_oz int[];      -- cells that left a view (and the old centre of that view)
        ad_conn int[]; ad_cx int[]; ad_cz int[]; ad_nx int[]; ad_nz int[];      -- cells that entered a view (and the new centre)
begin
    with gone as (delete from mc.entity_viewer_cell vc where not exists (select 1 from mc.player pl where pl.conn_id = vc.conn_id) returning conn_id)
    delete from mc.entity_cell_viewer v using gone g where v.conn_id = g.conn_id;
    select array_agg(pl.conn_id), array_agg(pl.chunk_x), array_agg(pl.chunk_z), array_agg(vc.cx), array_agg(vc.cz) into cc, ncx, ncz, ocx, ocz
      from mc.player pl left join mc.entity_viewer_cell vc on vc.conn_id = pl.conn_id
     where pl.conn_id is not null and (vc.conn_id is null or vc.cx <> pl.chunk_x or vc.cz <> pl.chunk_z or vc.r <> vr);
    if cc is null then return 0; end if;
    n := cardinality(cc);
    -- the rings first (a few dozen cells per crossing player), as arrays: the planner then knows how small the driving side is
    select array_agg(q.conn), array_agg(q.cx), array_agg(q.cz), array_agg(q.ox), array_agg(q.oz) into rm_conn, rm_cx, rm_cz, rm_ox, rm_oz
      from (select ch.conn, ch.ocx + dx as cx, ch.ocz + dz as cz, ch.ocx as ox, ch.ocz as oz
              from unnest(cc, ncx, ncz, ocx, ocz) ch(conn, ncx, ncz, ocx, ocz), generate_series(-vr, vr) dx, generate_series(-vr, vr) dz
             where ch.ocx is not null and (abs(ch.ocx + dx - ch.ncx) > vr or abs(ch.ocz + dz - ch.ncz) > vr)) q;
    select array_agg(q.conn), array_agg(q.cx), array_agg(q.cz), array_agg(q.nx), array_agg(q.nz) into ad_conn, ad_cx, ad_cz, ad_nx, ad_nz
      from (select ch.conn, ch.ncx + dx as cx, ch.ncz + dz as cz, ch.ncx as nx, ch.ncz as nz
              from unnest(cc, ncx, ncz, ocx, ocz) ch(conn, ncx, ncz, ocx, ocz), generate_series(-vr, vr) dx, generate_series(-vr, vr) dz
             where ch.ocx is null or abs(ch.ncx + dx - ch.ocx) > vr or abs(ch.ncz + dz - ch.ocz) > vr) q;
    if rm_conn is not null then
        -- what leaves the view: the entities in the cells that left it, within their tracking range of the OLD centre, are removed
        insert into mc.play_out (conn_id, data)
        select q.conn, mc.pkt_remove_entities(array_agg(q.eid order by q.eid))
          from (select r.conn, e.id as eid
                  from unnest(rm_conn, rm_cx, rm_cz, rm_ox, rm_oz) r(conn, cx, cz, ox, oz)
                  join mc.entity e on e.cx = r.cx and e.cz = r.cz and e.last_sent_tick > 0
                  join mc.entity_type_param p on p.type = e.type
                 where greatest(abs(r.ox - e.cx), abs(r.oz - e.cz)) <= least(vr, p.tracking_chunks)) q
         group by q.conn order by q.conn;
        delete from mc.entity_cell_viewer v using unnest(rm_conn, rm_cx, rm_cz) r(conn, cx, cz) where v.cx = r.cx and v.cz = r.cz and v.conn_id = r.conn;
    end if;
    if ad_conn is not null then
        -- what enters the view: the entities in the new cells within their tracking range of the NEW centre appear
        insert into mc.play_out (conn_id, data)
        select q.conn, string_agg(q.pkt, '\x'::bytea order by q.eid)
          from (select a.conn, e.id as eid, mc.epkt_appear(e.id, e.uuid, e.type, e.type_id, e.x, e.y, e.z, e.vx, e.vy, e.vz, e.yaw, e.pitch, e.data) as pkt
                  from unnest(ad_conn, ad_cx, ad_cz, ad_nx, ad_nz) a(conn, cx, cz, nx, nz)
                  join mc.entity e on e.cx = a.cx and e.cz = a.cz and e.last_sent_tick > 0
                  join mc.entity_type_param p on p.type = e.type
                 where greatest(abs(a.nx - e.cx), abs(a.nz - e.cz)) <= least(vr, p.tracking_chunks)) q
         group by q.conn order by q.conn;
        insert into mc.entity_cell_viewer (cx, cz, conn_id) select a.cx, a.cz, a.conn from unnest(ad_conn, ad_cx, ad_cz) a(conn, cx, cz) on conflict do nothing;
    end if;
    insert into mc.entity_viewer_cell (conn_id, cx, cz, r)
    select ch.conn, ch.ncx, ch.ncz, vr from unnest(cc, ncx, ncz) ch(conn, ncx, ncz)
    on conflict (conn_id) do update set cx = excluded.cx, cz = excluded.cz, r = excluded.r;
    return n;
end $$;

------------------------------------------------------------------------------------------------ the tracker
-- p_ids: the entities the physics step processed this tick (only they can have moved).  Step 1 announces new entities, step 2 sends movement.
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
                   || case when f.sync then mc.epkt_sync(f.id, f.x, f.y, f.z, f.vx, f.vy, f.vz, f.yaw, f.pitch, f.on_ground)
                        when f.pos_ch and f.rot_ch then case when f.linear_delta then mc.epkt_move_lin_rot(f.id, f.dx::int, f.dy::int, f.dz::int, f.yaw, f.pitch, f.on_ground)
                                                              else mc.pkt_move_entity_pos_rot(f.id, f.dx::int, f.dy::int, f.dz::int, (p_tick - f.last_sent_tick)::int, f.yaw, f.pitch, f.on_ground) end
                        when f.pos_ch then case when f.linear_delta then mc.epkt_move_lin(f.id, f.dx::int, f.dy::int, f.dz::int, f.on_ground)
                                                else mc.pkt_move_entity_pos(f.id, f.dx::int, f.dy::int, f.dz::int, (p_tick - f.last_sent_tick)::int, f.on_ground) end
                        when f.rot_ch then mc.pkt_move_entity_rot(f.id, f.yaw, f.pitch, f.on_ground)
                        else '\x'::bytea end
                   || case when f.kind = 'mob' and f.rot_ch then mc.pkt_rotate_head(f.id, f.yaw) else '\x'::bytea end as pkt,
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

------------------------------------------------------------------------------------------------ the entity tick
create or replace function mc.entity_tick(p_tick bigint default null) returns int language plpgsql volatile as $$
declare t bigint := coalesce(p_tick, (select game_time from mc.game_state limit 1), 0); ids int[]; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz;
        nsent int; npick int;
begin
    perform mc.entity_viewers_refresh(t);
    perform mc.entity_ai(t);
    if coalesce(current_setting('dbcraft.entity_spawner', true), 'on') <> 'off' then perform mc.entity_spawner(t); end if;       -- a switch for benchmarks and for servers that do not want natural spawning
    perform mc.entity_despawn(t);
    t1 := clock_timestamp();
    ids := mc.entity_physics_ids(t);
    t2 := clock_timestamp();
    nsent := mc.entity_tracker(t, ids);
    t3 := clock_timestamp();
    npick := mc.entity_pickup(t);
    t4 := clock_timestamp();
    insert into mc.entity_tick_log (tick, awake, moved, sent, packets, ms_physics, ms_ai, ms_tracker, ms_pickup, ms_total)
    values (t, cardinality(ids), nsent, nsent, 0, extract(epoch from t2 - t1) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t3 - t2) * 1000, extract(epoch from t4 - t3) * 1000, extract(epoch from t4 - t0) * 1000)
    on conflict (tick) do update set awake = excluded.awake, moved = excluded.moved, sent = excluded.sent, packets = excluded.packets, ms_physics = excluded.ms_physics, ms_ai = excluded.ms_ai,
                                     ms_tracker = excluded.ms_tracker, ms_pickup = excluded.ms_pickup, ms_total = excluded.ms_total;
    return cardinality(ids);
end $$;
