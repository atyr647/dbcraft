-- EXPLAIN (ANALYZE) of the lane step query of sql/541 for one tick (rolled back).  Needs the population of a bench_tick.sql run.
\set QUIET on
\set t 7011
select count(mc.entity_tick(g)) from generate_series(7000, 7010) g;
select set_config('dbcraft.entity_tick', :'t', false);
begin;
set local enable_hashjoin = off; set local enable_mergejoin = off;
explain (analyze, buffers off, costs off, timing on)
with due as materialized (select coalesce(array_agg(l.id), '{}') as ids from mc.entity_lane l where l.slot = (:t % l.every)::int and l.goal_until > :t),
cur as materialized (
        select e.id, e.cx, e.cz, e.y, e.yaw, e.pitch, e.on_ground, p.tracking_chunks as trk, (:t - e.born_tick) as tc,
               e.x + e.gx * (:t - e.phys_tick) as nx, e.z + e.gz * (:t - e.phys_tick) as nz,
               l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick
          from unnest((select ids from due)) d(id)
          join mc.entity e on e.id = d.id and e.lane_until > :t and e.phys_tick < :t
          join mc.entity_lane l on l.id = d.id
          join mc.entity_type_param p on p.type = e.type
    ), calc as materialized (
        select q.*, (q.dx * q.dx + q.dy * q.dy + q.dz * q.dz >= 128 or q.tc % 60 = 0) as pos_ch,
               (abs(mc.angle_byte(q.yaw) - mc.angle_byte(q.syaw)) >= 1) as rot_ch,
               (abs(q.dx) > 32767 or abs(q.dy) > 32767 or abs(q.dz) > 32767 or q.tc % 400 = 0) as sync
          from (select cur.*, mc.quant(cur.nx) as qx, mc.quant(cur.y) as qy, mc.quant(cur.nz) as qz,
                       mc.quant(cur.nx) - cur.sqx as dx, mc.quant(cur.y) - cur.sqy as dy, mc.quant(cur.nz) - cur.sqz as dz from cur) q
    ), pk as materialized (
        select c.id, c.cx, c.cz, c.trk,
               case when c.pos_ch then mc.epkt_mob_move(c.id, c.dx::int, c.dy::int, c.dz::int, (:t - c.last_tick)::int, c.on_ground, c.rot_ch, c.yaw, c.pitch)
                    else mc.pkt_move_entity_rot(c.id, c.yaw, c.pitch, c.on_ground) || mc.pkt_rotate_head(c.id, c.yaw) end as pkt
          from calc c where not c.sync and (c.pos_ch or c.rot_ch)
    ), fan as (
        insert into mc.play_out (conn_id, data)
        select v.conn_id, string_agg(pk.pkt, '\x'::bytea order by pk.id)
          from pk cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = pk.cx and vv.cz = pk.cz offset 0) v
          join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - pk.cx), abs(vc.cz - pk.cz)) <= pk.trk
         group by v.conn_id order by v.conn_id returning 1
    ), ul as (
        update mc.entity_lane l set sqx = case when c.pos_ch then c.qx else l.sqx end, sqy = case when c.pos_ch then c.qy else l.sqy end,
               sqz = case when c.pos_ch then c.qz else l.sqz end, syaw = case when c.rot_ch then c.yaw else l.syaw end,
               last_tick = case when c.pos_ch then :t else l.last_tick end
          from calc c where l.id = c.id and not c.sync returning l.id
    )
select (select count(*) from fan), (select count(*) from ul);
rollback;
