-- Player visibility, part 9: the locator bar (waypoint packets).  ServerWaypointManager / WaypointTransmitter / LivingEntity.makeWaypointConnectionWith (26.3, javap -c), compared
-- with what the real server sent (tests/e2e/vis_probe.py: join, pose, walk, range).
--
-- Every player transmits a waypoint to every other player (gamerule locator_bar, default true; the transmit and receive range are 60,000,000 blocks).  Per pair (receiver, source)
-- there is one CONNECTION of one of three kinds, decided by the source's position as the receiver sees it:
--   more than 332 blocks apart                        azimuth: the direction as a float (an UPDATE when it changed by more than 0.0087266 rad = half a degree)
--   else the source's chunk is outside the receiver's chunk view (Chebyshev distance > the receiver's view distance)   chunk: the chunk (an UPDATE when the source changed chunk)
--   else                                              block: the source's block position (an UPDATE when it changed by one block)
-- A connection is BROKEN, and remade (a TRACK of the new kind, no UNTRACK in between), when the block position jumped by more than one block (a teleport, a fast move),
-- the chunk by more than one, the chunk became visible (chunk kind) or the distance dropped below 332 (azimuth kind); it is dropped with an UNTRACK when the source does
-- not transmit any more.  A source does not transmit while it crouches (pose, one tick after the shift key: the waypoint follows the entity phase), wears a head that hides it
-- (carved pumpkin, mob heads: a transmit-range modifier of -100%) or when the receiver is not a spectator and the source is one.  A spectator receiver sees everybody.
-- Packet: VarInt op (0 track, 1 untrack, 2 update) | identifier: 0x01 + UUID | icon: string "minecraft:default" + no colour | VarInt type (0 empty, 1 block position, 2 chunk, 3 azimuth) | data.
-- The packets of a tick are sent in two places: movement (the connections' updates, before the tracker's packets: vanilla sends them when the movement packet is handled) and
-- state changes (crouching, game mode, a new player's first tick: in the entity phase, after the tracker's packets).
--
-- Cost: every pair is looked at twice a tick, N x N rows.  Fine for dozens of players; at hundreds it is the largest item of the tick.  gamerule locator_bar false stops it (vanilla's
-- own switch), and so does dbcraft.locator-bar-max-players (default 120): above that many players the bar is switched off (an UNTRACK for every connection once) and
-- comes back when the count drops.  Measured in docs/PLAYER-VISIBILITY.md.

create unlogged table if not exists mc.wp (rcv int not null, src int not null, kind smallint not null, ang real, primary key (rcv, src));
create index if not exists wp_src_idx on mc.wp (src);

alter table mc.player
    add column if not exists wp_bx int, add column if not exists wp_by int, add column if not exists wp_bz int,       -- the source's block / chunk as of the last pass (Connection.lastPosition)
    add column if not exists wp_cx int, add column if not exists wp_cz int,
    add column if not exists wp_state smallint,                                                                         -- bit 0: transmits, bit 1: spectator, as of the last entity phase; null = never ticked
    add column if not exists wp_hidden boolean not null default false;                                                  -- wears a head that hides it from the locator bar

insert into mc.server_property (key, value, default_value, note)
values ('dbcraft.locator-bar-max-players', '120', '120', 'dbcraft: above this many online players the locator bar (waypoint packets) is switched off; every pair of players costs a row per tick')
on conflict (key) do nothing;
insert into mc.server_property (key, value, default_value, note)
values ('dbcraft.locator-bar-untrack-slice', '1500', '1500', 'dbcraft: when the locator bar is switched off (more players than dbcraft.locator-bar-max-players, or the game rule) at most this many UNTRACK connections are ended per tick, the rest in the following ticks (one tick of 14,000 packets at 120 players took 1.5 s)')
on conflict (key) do nothing;

-- (sql/920, docs/PERF-STORM.md: written without proto.varint / proto.uuid / proto.string, which are PL/pgSQL calls or a text round trip: 130 us per packet before, 3 us now; the same bytes,
-- tests/sql/920 compares it with the previous body.  A joiner is sent a packet per transmitting player and the bar's pass builds one per changed pair.)
create or replace function mc.wp_body(p_op int, p_uuid uuid, p_kind int, p_a int, p_b int, p_c int, p_ang real) returns bytea language sql immutable parallel safe as $$
  select proto.varint_slow(p_op) || '\x01'::bytea || uuid_send(p_uuid) || '\x116d696e6563726166743a64656661756c7400'::bytea      -- op | 0x01 + uuid | "minecraft:default" | no colour
         || case p_kind when 1 then '\x01'::bytea || proto.varint_slow(p_a) || proto.varint_slow(p_b) || proto.varint_slow(p_c)
                        when 2 then '\x02'::bytea || proto.varint_slow(p_a) || proto.varint_slow(p_b)
                        when 3 then '\x03'::bytea || float4send(p_ang)
                        else '\x00'::bytea end $$;
create or replace function mc.pkt_waypoint(p_op int, p_uuid uuid, p_kind int, p_a int, p_b int, p_c int, p_ang real) returns bytea language sql stable parallel safe as $$
  select mc.cb('waypoint', mc.wp_body(p_op, p_uuid, p_kind, p_a, p_b, p_c, p_ang)) $$;

-- the azimuth of the source as the receiver sees it: Mth.atan2 of the receiver-to-source offset turned a quarter clockwise (WaypointTransmitter.EntityAzimuthConnection)
create or replace function mc.wp_angle(rx float8, rz float8, sx float8, sz float8) returns real language sql immutable parallel safe as $$
  select atan2(rx - sx, -(rz - sz))::real $$;

create or replace function mc.wp_state_now(p mc.player) returns int language sql immutable parallel safe as $$
  select (case when p.pose <> 5 and not p.wp_hidden then 1 else 0 end) | (case when p.gamemode = 3 then 2 else 0 end) $$;

-- one pass over all pairs.  p_phase 1: movement (positions as applied this tick, the transmit state as of the last entity phase); p_phase 2: the entity phase (the state now, remembered).
drop function if exists mc.vis_wp_pass(bigint, int);
create or replace function mc.vis_wp_pass(p_cur bigint, p_phase int, p_n int default null) returns void language plpgsql as $$
declare enabled boolean := mc.rule_bool('locator_bar', true); n int; cap int := coalesce(mc.prop_int('dbcraft.locator-bar-max-players'), 120);
        slice int := coalesce(mc.prop_int('dbcraft.locator-bar-untrack-slice'), 2000000000); vdsrv int := mc.prop_int('view-distance');      -- (once, not once per player row: 20 us each)
begin
  n := coalesce(p_n, (select count(*)::int from mc.player where conn_id is not null));
  if n > cap then enabled := false; end if;
  if not enabled and not exists (select 1 from mc.wp) then return; end if;       -- off and nothing connected: nothing to do, not even the bookkeeping (the first pass after it comes back remakes what it needs)
  if not enabled then
    -- sql/920 (docs/PERF-STORM.md): the bar is off (over the player cap or the game rule), so every connection is to be ended: no pair needs evaluating, the rows are taken in (receiver, source)
    -- order, at most dbcraft.locator-bar-untrack-slice of them, and their UNTRACKs go out grouped by receiver in source order, exactly the packets of the general pass below.  (The general pass
    -- looked at every pair of players for every slice: 14,000 pairs, 450 ms, in each of the ten ticks that ended the 14,000 connections of 120 players.)
    with e0 as (select w.rcv, w.src from mc.wp w order by w.rcv, w.src limit slice),         -- (the slice first, from the primary key; the players only for those rows: joining all 14,000 first cost 400 ms)
         del as (delete from mc.wp w using e0 where w.rcv = e0.rcv and w.src = e0.src returning w.rcv, w.src)      -- (a row whose receiver or source is not online any more is dropped without a packet)
    insert into mc.play_out (conn_id, data)
    select r.conn_id, string_agg(mc.pkt_waypoint(1, s.uuid, 0, 0, 0, 0, 0), '\x'::bytea order by d.src)
      from del d join mc.player r on r.entity_id = d.rcv and r.conn_id is not null join mc.player s on s.entity_id = d.src and s.conn_id is not null
     group by r.conn_id order by r.conn_id;
  else
  with pl as materialized (
    select p.entity_id as eid, p.conn_id, p.uuid, p.x, p.y, p.z, p.last_move_tick, p.wp_state as old_st, floor(p.x)::int as bx, floor(p.y)::int as by, floor(p.z)::int as bz, p.chunk_x as cx, p.chunk_z as cz,
           p.wp_bx, p.wp_by, p.wp_bz, p.wp_cx, p.wp_cz,
           case when p_phase = 2 then mc.wp_state_now(p) else p.wp_state end as st,
           coalesce(case when p.view_distance_req is null then 2 else greatest(2, least(p.view_distance_req, vdsrv)) end, 2) as vr
      from mc.player p where p.conn_id is not null),
  -- (docs/PERF-CAPACITY.md) pr and dc are NOT materialized: they are N x N rows of twenty columns each, and writing them to a tuplestore twice cost more than the expressions they save (100 walkers: 79 -> 48-58 ms of
  -- tick CPU, 50 walkers: 39 -> 30; the same rows, only the events are kept)
  pr as (
    select r.eid as rcv, r.conn_id as rconn, s.eid as src, s.uuid as suuid, s.bx, s.by, s.bz, s.cx as scx, s.cz as scz,
           (enabled and s.st is not null and (s.st & 1) = 1 and not ((coalesce(r.st, 0) & 2) = 0 and (s.st & 2) = 2)) as want,
           (sqrt((r.x - s.x) ^ 2 + (r.y - s.y) ^ 2 + (r.z - s.z) ^ 2)::real > 332::real) as far,
           (abs(s.cx - r.cx) <= r.vr and abs(s.cz - r.cz) <= r.vr) as vis,
           (abs(s.bx - coalesce(s.wp_bx, s.bx)) + abs(s.by - coalesce(s.wp_by, s.by)) + abs(s.bz - coalesce(s.wp_bz, s.bz))) as manh,
           greatest(abs(s.cx - coalesce(s.wp_cx, s.cx)), abs(s.cz - coalesce(s.wp_cz, s.cz))) as cheb,
           mc.wp_angle(r.x, r.z, s.x, s.z) as ang,
           ((p_phase = 1 and r.last_move_tick = p_cur) or (p_phase = 2 and (s.old_st is null or ((s.st & 1) = 1 and (s.old_st & 1) = 0)))) as may_create,      -- a missing connection is made when the receiver moves (updatePlayer) or when the source starts to transmit (trackWaypoint)
           w.kind as ok, w.ang as oang
      from pl r join pl s on s.eid <> r.eid and (p_phase = 1 or not enabled or r.st is distinct from r.old_st or s.st is distinct from s.old_st)      -- sql/920: the entity phase (2) only looks at pairs of which one side's transmit state changed (everything else was settled by the movement pass or has nothing to decide)
                   left join mc.wp w on w.rcv = r.eid and w.src = s.eid),
  dc as (
    select pr.*, case when far then 3 when not vis then 2 else 1 end as nk,
           case when ok is null then null
                when not want then 'untrack'
                when ok = 1 and manh > 1 then 'remake' when ok = 2 and (cheb > 1 or vis) then 'remake' when ok = 3 and (vis or not far) then 'remake'
                when ok = 1 and manh > 0 then 'update' when ok = 2 and cheb > 0 then 'update' when ok = 3 and abs(ang - oang) > 0.008726646::real then 'update' end as act
      from pr),
  ev as materialized (
    select dc.rcv, dc.rconn, dc.src,
           case when dc.ok is null then 'track' else dc.act end as what, dc.nk, dc.ok, dc.suuid, dc.bx, dc.by, dc.bz, dc.scx, dc.scz, dc.ang
      from dc where (dc.ok is null and dc.want and dc.may_create) or dc.act is not null),
  ins as (
    insert into mc.wp (rcv, src, kind, ang) select ev.rcv, ev.src, ev.nk, ev.ang from ev where ev.what = 'track'
    on conflict (rcv, src) do update set kind = excluded.kind, ang = excluded.ang returning 1),
  rem as (
    update mc.wp w set kind = ev.nk, ang = ev.ang from ev where ev.what = 'remake' and w.rcv = ev.rcv and w.src = ev.src returning 1),
  upd as (
    update mc.wp w set ang = ev.ang from ev where ev.what = 'update' and ev.ok = 3 and w.rcv = ev.rcv and w.src = ev.src returning 1),
  del as (
    delete from mc.wp w using ev where ev.what = 'untrack' and w.rcv = ev.rcv and w.src = ev.src returning 1)
  insert into mc.play_out (conn_id, data)
  select ev.rconn, string_agg(case ev.what
           when 'track'   then mc.pkt_waypoint(0, ev.suuid, ev.nk, case ev.nk when 1 then ev.bx else ev.scx end, case ev.nk when 1 then ev.by else ev.scz end, ev.bz, ev.ang)
           when 'remake'  then mc.pkt_waypoint(0, ev.suuid, ev.nk, case ev.nk when 1 then ev.bx else ev.scx end, case ev.nk when 1 then ev.by else ev.scz end, ev.bz, ev.ang)
           when 'update'  then mc.pkt_waypoint(2, ev.suuid, ev.ok, case ev.ok when 1 then ev.bx else ev.scx end, case ev.ok when 1 then ev.by else ev.scz end, ev.bz, ev.ang)
           else mc.pkt_waypoint(1, ev.suuid, 0, 0, 0, 0, 0) end, '\x'::bytea order by ev.src)
    from ev group by ev.rconn order by ev.rconn;
  end if;
  if p_phase = 1 then
    update mc.player set wp_bx = floor(x)::int, wp_by = floor(y)::int, wp_bz = floor(z)::int, wp_cx = chunk_x, wp_cz = chunk_z
     where conn_id is not null and (wp_bx is distinct from floor(x)::int or wp_by is distinct from floor(y)::int or wp_bz is distinct from floor(z)::int or wp_cx is distinct from chunk_x or wp_cz is distinct from chunk_z);
  else
    update mc.player p set wp_state = mc.wp_state_now(p) where p.conn_id is not null and p.wp_state is distinct from mc.wp_state_now(p);
  end if;
end $$;

-- A joining player is connected to every transmitting player right away (ServerWaypointManager.addPlayer): the rows, and the packets of the entry burst (sql/906).
create or replace function mc.vis_wp_join(p_eid int) returns void language plpgsql as $$
declare enabled boolean := mc.rule_bool('locator_bar', true); vdsrv int := mc.prop_int('view-distance');
begin
  if not enabled or (select count(*) from mc.player where conn_id is not null) > coalesce(mc.prop_int('dbcraft.locator-bar-max-players'), 120) then return; end if;
  insert into mc.wp (rcv, src, kind, ang)
  select r.entity_id, s.entity_id,
         case when sqrt((r.x - s.x) ^ 2 + (r.y - s.y) ^ 2 + (r.z - s.z) ^ 2)::real > 332::real then 3
              when abs(s.chunk_x - r.chunk_x) <= coalesce(greatest(2, least(r.view_distance_req, vdsrv)), 2) and abs(s.chunk_z - r.chunk_z) <= coalesce(greatest(2, least(r.view_distance_req, vdsrv)), 2) then 1 else 2 end,
         mc.wp_angle(r.x, r.z, s.x, s.z)
    from mc.player r join mc.player s on s.entity_id <> r.entity_id and s.conn_id is not null and s.wp_state is not null and (s.wp_state & 1) = 1 and not ((r.gamemode <> 3) and (s.wp_state & 2) = 2)
   where r.entity_id = p_eid
  on conflict (rcv, src) do nothing;
  insert into mc.play_out (conn_id, data)
  select r.conn_id, string_agg(mc.pkt_waypoint(0, q.uuid, q.kind::int, case q.kind when 1 then floor(q.x)::int else q.chunk_x end, case q.kind when 1 then floor(q.y)::int else q.chunk_z end, floor(q.z)::int, q.ang), '\x'::bytea order by q.rk)
    from mc.player r join (select s.uuid, w.kind, s.x, s.y, s.z, s.chunk_x, s.chunk_z, w.ang, row_number() over (order by s.entity_id) as rk
                             from mc.wp w join mc.player s on s.entity_id = w.src where w.rcv = p_eid) q on q.rk > 9
   where r.entity_id = p_eid group by r.conn_id;
end $$;

-- the first nine of them are part of the entry burst (ords 201-209, between the chunk cache centre and post_effects); the rest follow it through the tick's queue
create or replace function mc.wp_join_packets(p_eid int) returns table(ord int, packet text, body bytea) language sql stable as $$
  select 200 + q.rk::int, 'minecraft:waypoint',
         mc.wp_body(0, q.uuid, q.kind::int, case q.kind when 1 then floor(q.x)::int else q.chunk_x end, case q.kind when 1 then floor(q.y)::int else q.chunk_z end, floor(q.z)::int, q.ang)
    from (select s.uuid, w.kind, s.x, s.y, s.z, s.chunk_x, s.chunk_z, w.ang, row_number() over (order by s.entity_id) as rk
            from mc.wp w join mc.player s on s.entity_id = w.src where w.rcv = p_eid) q where q.rk <= 9 $$;
