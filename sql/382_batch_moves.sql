-- Batched pipeline, part 3: movement (flag `mv`).  The same rules, decoded the same way, as mc.apply_player_moves() (sql/340), as ONE statement:
--   decode -> rule violations (kick) -> teleport confirmations -> last position/rotation per connection -> moved-too-quickly check (correction) -> apply -> broadcast.
-- Differences in HOW, none in WHAT (byte-identical output and the same final mc.player state; tests/sql/387_batch_differential.sql checks it on random traffic):
--   * no temp tables, no ANALYZE, no indexes created per tick (the baseline's per-tick DDL-like work invalidated plans and cost ~15% of this phase);
--   * every player's new state is computed once and written with ONE update (the baseline updates a mover twice: the apply step and the sent_* step);
--   * mc.play_out gets one ordered insert: kick packets, then corrections, then the fan-out, so a connection's rows are in the baseline's order.
-- The statement must not update a row twice (PostgreSQL allows one update per row per statement): confirmation, correction, apply and sent_* are folded into `eff`.
create or replace function mc.moves_batched(cur_tick bigint) returns table(moved int, corrected int, kicked int) language plpgsql as $$
declare
  iv int := coalesce(nullif((select value::int from mc.server_property where key = 'dbcraft.player-update-interval'), 0), 2);   -- vanilla: a player's update interval is 2 ticks (EntityType.PLAYER.updateInterval(2); sendChanges runs its body when tickCount % 2 = 0; each ServerEntity counts from its own creation, so the phase differs per entity: here (tick + entity id) % interval)
  i_pos int := mc.sid('move_player_pos'); i_pr int := mc.sid('move_player_pos_rot'); i_rot int := mc.sid('move_player_rot');
  i_st int := mc.sid('move_player_status_only'); i_te int := mc.sid('client_tick_end'); i_tp int := mc.sid('accept_teleportation');
  c_pos int := mc.pid('move_entity_pos'); c_pr int := mc.pid('move_entity_pos_rot'); c_rot int := mc.pid('move_entity_rot'); c_head int := mc.pid('rotate_head');
  kick_nbt bytea := proto.nbt_root(mc.disconnect_nbt('multiplayer.disconnect.invalid_player_movement', null));
  kick_pkt bytea := mc.pkt_disconnect(proto.nbt_root(mc.disconnect_nbt('multiplayer.disconnect.invalid_player_movement', null)));
  f_eid int[]; f_data bytea[]; f_ocx int[]; f_ocz int[]; v_conn int[]; v_eid int[]; v_cx int[]; v_cz int[]; any_dirty boolean;   -- the fan-out's inputs (sql/430_tick_perf_fanout.sql)
begin
  with
  raw as materialized (select m.seq, m.conn_id, m.packet_id, m.body from mc.play_in_work m where m.packet_id in (i_pos, i_pr, i_rot, i_st, i_te, i_tp)),
  -- 1. decode (fixed sizes: pos 25 bytes, pos_rot 33, rot 9, status 1; anything else is malformed)
  dec as materialized (
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
      from raw m where m.packet_id in (i_pos, i_pr, i_rot, i_st, i_te)),
  win as materialized (
    select d.*, coalesce(sum((d.kind = 't')::int) over (partition by d.conn_id order by d.seq rows between unbounded preceding and 1 preceding), 0) as seg from dec d),
  num as materialized (
    select w.*, case when w.kind in ('p', 'b') then row_number() over (partition by w.conn_id, w.seg, w.kind in ('p', 'b') order by w.seq) end as pos_n,
           w.kind = 'x' or coalesce(w.x in ('NaN', 'Infinity', '-Infinity') or w.y in ('NaN', 'Infinity', '-Infinity') or w.z in ('NaN', 'Infinity', '-Infinity')
                                    or w.yaw in ('NaN', 'Infinity', '-Infinity') or w.pitch in ('NaN', 'Infinity', '-Infinity'), false) as bad
      from win w),
  -- 2. rule violations: disconnect, and ignore the rest of that connection's packets
  kk as materialized (select distinct conn_id from num where pos_n > 1 or bad),
  ok as materialized (select n.* from num n where not exists (select 1 from kk where kk.conn_id = n.conn_id)),
  -- 3. teleport confirmations (all of them, also from connections that are being kicked, like the baseline)
  conf as materialized (select r.conn_id, proto.varint_safe(r.body, 0) as tid from raw r where r.packet_id = i_tp),
  -- 4. the last position, last rotation and last on-ground flag of each connection
  lp as materialized (select distinct on (conn_id) conn_id, x, y, z from ok where kind in ('p', 'b') order by conn_id, seq desc),
  lr as materialized (select distinct on (conn_id) conn_id, yaw, pitch from ok where kind in ('b', 'r') order by conn_id, seq desc),
  lf as materialized (select distinct on (conn_id) conn_id, flags from ok where kind in ('p', 'b', 'r', 's') order by conn_id, seq desc),
  act as materialized (select distinct conn_id from ok where kind <> 't'),
  pl as materialized (
    select p.uuid, p.conn_id, p.entity_id, p.x, p.y, p.z, p.yaw, p.pitch, p.on_ground, p.chunk_x, p.chunk_z, p.vis_dirty, p.teleport_id, p.awaiting_teleport,
           p.sent_qx, p.sent_qy, p.sent_qz, p.sent_yaw, p.sent_pitch, p.last_sent_tick,
           (p.awaiting_teleport is not null and exists (select 1 from conf c where c.conn_id = p.conn_id and c.tid = p.awaiting_teleport)) as conf_hit,
           (a.conn_id is not null) as is_act, lp.x as nx, lp.y as ny, lp.z as nz, (lp.conn_id is not null) as has_pos,
           lr.yaw as nyaw, lr.pitch as npitch, (lr.conn_id is not null) as has_rot, lf.flags
      from mc.player p
      left join act a on a.conn_id = p.conn_id left join lp on lp.conn_id = p.conn_id left join lr on lr.conn_id = p.conn_id left join lf on lf.conn_id = p.conn_id
     where p.conn_id is not null),
  -- 5. players that may move this tick (a pending teleport confirmation blocks movement, a confirmation in this very tick unblocks it);
  --    moved too quickly (squared distance > 100 from where the server has the player) => ignore the move and send a correction under a new teleport id
  st1 as materialized (
    select s.*, (s.is_act and (s.awaiting_teleport is null or s.conf_hit)) as in_fin,
           (s.is_act and (s.awaiting_teleport is null or s.conf_hit) and s.has_pos and ((s.nx - s.x) ^ 2 + (s.ny - s.y) ^ 2 + (s.nz - s.z) ^ 2) > 100) as too_fast
      from pl s),
  -- 6. the effective state after this tick's input (coordinates clamped like vanilla: x,z to +-3.0E7, y to +-2.0E7; pitch to +-90)
  eff as materialized (
    select s.uuid, s.conn_id, s.entity_id, s.conf_hit, s.too_fast, s.teleport_id, s.awaiting_teleport, s.vis_dirty, s.chunk_x, s.chunk_z,
           s.sent_qx, s.sent_qy, s.sent_qz, s.sent_yaw, s.sent_pitch, s.last_sent_tick,
           s.x as ox, s.y as oy, s.z as oz, s.yaw as oyaw, s.pitch as opitch,
           (s.in_fin and not s.too_fast) as applied,
           (s.in_fin and not s.too_fast and s.has_pos) as moved_pos,
           (s.in_fin and not s.too_fast and s.has_pos and (floor(s.nx / 16)::int <> s.chunk_x or floor(s.nz / 16)::int <> s.chunk_z)) as crossed,
           case when s.in_fin and not s.too_fast and s.has_pos then greatest(-3.0e7, least(3.0e7, s.nx)) else s.x end as ex,
           case when s.in_fin and not s.too_fast and s.has_pos then greatest(-2.0e7, least(2.0e7, s.ny)) else s.y end as ey,
           case when s.in_fin and not s.too_fast and s.has_pos then greatest(-3.0e7, least(3.0e7, s.nz)) else s.z end as ez,
           case when s.in_fin and not s.too_fast and s.has_rot then s.nyaw else s.yaw end as eyaw,
           case when s.in_fin and not s.too_fast and s.has_rot then greatest(-90, least(90, s.npitch)) else s.pitch end as epitch,
           case when s.in_fin and not s.too_fast then coalesce((s.flags & 1) = 1, s.on_ground) else s.on_ground end as eground
      from st1 s),
  -- 7. tell the viewers: the packet per mover is built ONCE (MATERIALIZED, see sql/340) and fanned out, concatenated per viewer connection
  mv as materialized (
    select e.entity_id as eid, e.chunk_x as ocx, e.chunk_z as ocz, e.uuid, e.ex as x, e.ey as y, e.ez as z, e.eyaw as yaw, e.epitch as pitch, e.eground as on_ground,
           mc.quant(e.ex) - e.sent_qx as dx, mc.quant(e.ey) - e.sent_qy as dy, mc.quant(e.ez) - e.sent_qz as dz,
           (e.eyaw <> e.sent_yaw or e.epitch <> e.sent_pitch) as rot_changed, least(greatest(cur_tick - e.last_sent_tick, 1), iv)::int as ticks
      from eff e
     where (cur_tick + e.entity_id) % iv = 0 and (mc.quant(e.ex) <> e.sent_qx or mc.quant(e.ey) <> e.sent_qy or mc.quant(e.ez) <> e.sent_qz or e.eyaw <> e.sent_yaw or e.epitch <> e.sent_pitch)),
  pk as materialized (
    select mv.eid, mv.ocx, mv.ocz,
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
  cr as materialized (select e.conn_id, e.teleport_id + 1 as tid, e.ox as x, e.oy as y, e.oz as z, e.oyaw as yaw, e.opitch as pitch from eff e where e.too_fast),
  -- the one update per player
  upd as (
    update mc.player p set
        x = e.ex, y = e.ey, z = e.ez, yaw = e.eyaw, pitch = e.epitch, on_ground = e.eground,
        chunk_x = case when e.moved_pos then floor(e.ex / 16)::int else e.chunk_x end,
        chunk_z = case when e.moved_pos then floor(e.ez / 16)::int else e.chunk_z end,
        vis_dirty = e.vis_dirty or e.crossed,
        teleport_id = case when e.too_fast then e.teleport_id + 1 else e.teleport_id end,
        awaiting_teleport = case when e.too_fast then e.teleport_id + 1 when e.conf_hit then null else e.awaiting_teleport end,
        sent_qx = case when m.uuid is not null then mc.quant(e.ex) else e.sent_qx end,
        sent_qy = case when m.uuid is not null then mc.quant(e.ey) else e.sent_qy end,
        sent_qz = case when m.uuid is not null then mc.quant(e.ez) else e.sent_qz end,
        sent_yaw = case when m.uuid is not null then e.eyaw else e.sent_yaw end,
        sent_pitch = case when m.uuid is not null then e.epitch else e.sent_pitch end,
        last_sent_tick = case when m.uuid is not null then cur_tick else e.last_sent_tick end
      from eff e left join mv m on m.uuid = e.uuid
     where p.uuid = e.uuid and (e.applied or e.too_fast or e.conf_hit or m.uuid is not null)
    returning 1),
  kins as (insert into mc.kick (conn_id, reason_nbt) select conn_id, kick_nbt from kk on conflict do nothing returning 1),
  outq as (
    insert into mc.play_out (conn_id, data)
    select conn_id, data from (
      select conn_id, 1 as ph, kick_pkt as data from kk
      union all
      select conn_id, 2, mc.pkt_player_position(tid, x, y, z, 0, 0, 0, yaw, pitch, 0) from cr
    ) u order by ph
    returning 1),
  dlt as (delete from mc.play_in_work where packet_id in (i_pos, i_pr, i_rot, i_st, i_te, i_tp) returning 1)
  select (select count(*) from mv)::int, (select count(*) from cr)::int, (select count(*) from kk)::int,
         coalesce((select array_agg(pk.eid order by pk.eid) from pk), '{}'), coalesce((select array_agg(pk.data order by pk.eid) from pk), '{}'),
         coalesce((select array_agg(pk.ocx order by pk.eid) from pk), '{}'), coalesce((select array_agg(pk.ocz order by pk.eid) from pk), '{}'),
         coalesce((select array_agg(e.conn_id order by e.conn_id) from eff e where e.conn_id is not null), '{}'),
         coalesce((select array_agg(e.entity_id order by e.conn_id) from eff e where e.conn_id is not null), '{}'),
         coalesce((select array_agg(e.chunk_x order by e.conn_id) from eff e where e.conn_id is not null), '{}'),
         coalesce((select array_agg(e.chunk_z order by e.conn_id) from eff e where e.conn_id is not null), '{}'),
         coalesce((select bool_or(e.vis_dirty) from eff e where e.conn_id is not null), false)
    into moved, corrected, kicked, f_eid, f_data, f_ocx, f_ocz, v_conn, v_eid, v_cx, v_cz, any_dirty;
  -- phase 3 of the ordered output (after kicks and corrections): the viewers' movement packets, one blob per occupied chunk in a crowd
  perform mc.fanout_moves(f_eid, f_data, f_ocx, f_ocz, v_conn, v_eid, v_cx, v_cz, any_dirty);
  return next;
end $$;
