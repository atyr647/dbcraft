-- Game module, part 5: serverbound input.  Packets arrive in mc.play_in_work (conn_id, packet_id, body) in arrival order (seq).
-- All of it is decoded and applied set-based, once per tick.  A malformed packet must never abort the tick for everybody,
-- so fixed-size packets are length-checked and the few variable ones use exception-safe decoders.
--
-- Rules measured on the real 26.3 server (tools/game_probe.py scenarios movetest, moveseq*, dist):
--   * two position-carrying packets (move_player_pos / move_player_pos_rot) with no client_tick_end between them => disconnect
--     "multiplayer.disconnect.invalid_player_movement".  Rotation-only and status-only packets are not limited (up to 5 tried).
--   * NaN or infinite coordinates/angles => the same disconnect.  Coordinates beyond +-3.0E7 are accepted (clamped); yaw 400 and pitch 120 are accepted.
--   * one packet that moves a stationary player by more than 10 blocks (squared distance > 100; 9.9 accepted, 10.1 refused, in survival and creative)
--     => the server ignores it and sends player_position with a new teleport id; moves are ignored until accept_teleportation echoes that id.

create or replace function mc.sid(pname text) returns int language sql stable parallel safe as $$
  select (select protocol_id from ref.packet where state = 'play' and direction = 'serverbound' and name = 'minecraft:' || pname) $$;   -- scalar subselect: inlinable

create or replace function proto.varint_safe(b bytea, off int default 0) returns int language plpgsql immutable parallel safe as $$
begin return (proto.varint_read(b, off)).val; exception when others then return null; end $$;

-- Opt-in stopwatch for profiling a function body: `set mc.profile = 'on'` makes each mc.prof(label) call print the milliseconds since the previous call.
create or replace function mc.prof(label text) returns void language plpgsql as $$
declare last_ts timestamptz; now_ts timestamptz := clock_timestamp();
begin
  if current_setting('mc.profile', true) is distinct from 'on' then return; end if;
  last_ts := nullif(current_setting('mc.prof_last', true), '')::timestamptz;
  if label <> 'start' and last_ts is not null then raise notice 'prof % : % ms', label, round((extract(epoch from now_ts - last_ts) * 1000)::numeric, 1); end if;
  perform set_config('mc.prof_last', now_ts::text, false);
end $$;

------------------------------------------------------------------------------------------------ movement
create or replace function mc.apply_player_moves(cur_tick bigint) returns table(moved int, corrected int, kicked int) language plpgsql as $$
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

------------------------------------------------------------------------------------------------ keep-alive, held slot, creative slot
-- serverbound layouts (bytecode): keep_alive = long; set_carried_item = short; set_creative_mode_slot = short slot + ItemStack
-- (VarInt count [0 = empty], VarInt item id, VarInt added components, VarInt removed components, then the component entries).
create or replace function mc.apply_misc_input(cur_tick bigint) returns table(creative_slots int, held int, alive int) language plpgsql as $$
declare i_ka int := mc.sid('keep_alive'); i_held int := mc.sid('set_carried_item'); i_cs int := mc.sid('set_creative_mode_slot');
        r record; slot int; cnt int; iid int; item text; o int; added int;
begin
  creative_slots := 0;
  -- keep-alive answers: latency is smoothed like vanilla ((3 * old + sample) / 4)
  update mc.player p set latency_ms = ((p.latency_ms * 3 + ((cur_tick - p.keepalive_sent_tick) * 50)::int) / 4), keepalive_id = null
    from mc.play_in_work m where m.packet_id = i_ka and length(m.body) = 8 and p.conn_id = m.conn_id and p.keepalive_id = proto.i64_read(m.body, 0);
  get diagnostics alive = row_count;
  update mc.player p set held_slot = proto.i16_read(m.body, 0)
    from mc.play_in_work m where m.packet_id = i_held and length(m.body) = 2 and p.conn_id = m.conn_id and proto.i16_read(m.body, 0) between 0 and 8;
  get diagnostics held = row_count;
  for r in select m.seq, m.body, p.uuid, p.gamemode from mc.play_in_work m join mc.player p on p.conn_id = m.conn_id where m.packet_id = i_cs order by m.seq loop
    continue when r.gamemode <> 1 or length(r.body) < 3;                        -- only creative players may set slots
    slot := proto.i16_read(r.body, 0); continue when slot not between 0 and 45;
    cnt := proto.varint_safe(r.body, 2); continue when cnt is null;
    if cnt <= 0 then perform mc.set_slot(r.uuid, slot, null, 0); creative_slots := creative_slots + 1; continue; end if;
    o := (select nxt from proto.varint_read(r.body, 2));                         -- varint_read returns the absolute next offset
    iid := proto.varint_safe(r.body, o); continue when iid is null;
    select name into item from ref.registry where registry = 'minecraft:item' and protocol_id = iid; continue when item is null;
    o := (select nxt from proto.varint_read(r.body, o));
    added := proto.varint_safe(r.body, o);
    -- component entries are not decoded: a stack with data components is stored with its raw bytes (hex) so nothing is lost silently
    perform mc.set_slot(r.uuid, slot, item, least(cnt, 99), case when coalesce(added, 0) > 0 or length(r.body) > o + 2 then jsonb_build_object('raw_hex', encode(substring(r.body from o + 1), 'hex')) end);
    creative_slots := creative_slots + 1;
  end loop;
  delete from mc.play_in_work where packet_id in (i_ka, i_held, i_cs);
  return next;
end $$;

------------------------------------------------------------------------------------------------ keep-alive scheduling
-- Vanilla sends a keep-alive every 15 s (300 ticks) and kicks a client that has not answered for 30 s ("disconnect.timeout").
create or replace function mc.keepalive_due(cur_tick bigint) returns table(sent int, timed_out int) language plpgsql as $$
declare dead int[];
begin
  select coalesce(array_agg(conn_id), '{}') into dead from mc.player where conn_id is not null and keepalive_id is not null and cur_tick - keepalive_sent_tick >= 600;
  perform mc.kick(c, 'disconnect.timeout') from unnest(dead) c;
  timed_out := coalesce(array_length(dead, 1), 0);
  with due as (
    update mc.player set keepalive_id = cur_tick, keepalive_sent_tick = cur_tick
     where conn_id is not null and keepalive_id is null and (keepalive_sent_tick is null or cur_tick - keepalive_sent_tick >= 300)
    returning conn_id, keepalive_id),
  q as (insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_keep_alive(keepalive_id) from due returning 1)
  select count(*)::int into sent from due;
  return next;
end $$;
