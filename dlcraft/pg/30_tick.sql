-- Players, visibility and the tick.  (PostgreSQL has no rint(); round(float8) IS rint: round half to even on glibc, checked in test.sql.)  The tick is set-based: one statement per phase, candidate pairs found through the (chunk_x, chunk_z) index,
-- each mover's packet built once and fanned out by a join.

------------------------------------------------------------------------------------------------ packets (SPEC 6)
create function mc.pkt_add_entity(eid int, uuid bytea, x float8, y float8, z float8, yaw float4, pitch float4) returns bytea
language sql immutable parallel safe as $$
  select mc.frame('\x01'::bytea || mc.varint(eid) || uuid || float8send(x) || float8send(y) || float8send(z)
                  || set_byte(set_byte('\x0000'::bytea, 0, mc.angle(yaw)), 1, mc.angle(pitch))) $$;

create function mc.pkt_remove_entity(eid int) returns bytea language sql immutable parallel safe as $$
  select mc.frame('\x0201'::bytea || mc.varint(eid)) $$;

-- move_entity when every quantised delta fits an i16 (|d| <= 32767), else teleport_entity with the absolute position (SPEC 6 step 4)
create function mc.pkt_move(eid int, dqx bigint, dqy bigint, dqz bigint, x float8, y float8, z float8, yaw float4, pitch float4, og boolean) returns bytea
language sql immutable parallel safe as $$
  select mc.frame(case
    when abs(dqx) <= 32767 and abs(dqy) <= 32767 and abs(dqz) <= 32767 then
      '\x03'::bytea || mc.varint(eid) || int2send(dqx::int2) || int2send(dqy::int2) || int2send(dqz::int2)
      || set_byte(set_byte(set_byte('\x000000'::bytea, 0, mc.angle(yaw)), 1, mc.angle(pitch)), 2, case when og then 1 else 0 end)
    else
      '\x04'::bytea || mc.varint(eid) || float8send(x) || float8send(y) || float8send(z)
      || set_byte(set_byte(set_byte('\x000000'::bytea, 0, mc.angle(yaw)), 1, mc.angle(pitch)), 2, case when og then 1 else 0 end)
    end) $$;

-- i64 pos = ((x & 0x3FFFFFF) << 38) | ((z & 0x3FFFFFF) << 12) | (y & 0xFFF)
create function mc.pos64(x int, y int, z int) returns bytea language sql immutable parallel safe as $$
  select int8send(((x & 67108863)::bigint << 38) | ((z & 67108863)::bigint << 12) | (y & 4095)) $$;

create function mc.pkt_block_update(x int, y int, z int, new_state int) returns bytea language sql immutable parallel safe as $$
  select mc.frame('\x05'::bytea || mc.pos64(x, y, z) || mc.varint(new_state)) $$;

create function mc.pkt_fill_update(x int, y int, z int, new_state int, cnt int) returns bytea language sql immutable parallel safe as $$
  select mc.frame('\x06'::bytea || mc.pos64(x, y, z) || mc.varint(new_state) || mc.varint(cnt)) $$;

------------------------------------------------------------------------------------------------ players
create function mc.reset_players() returns void language sql as $$
  truncate mc.player, mc.visible, mc.inbox, mc.outbox restart identity;
  update mc.game_state set game_time = 0 $$;

create function mc.join_bulk(eids int[], xs float8[], ys float8[], zs float8[]) returns void language sql as $$
  insert into mc.player (eid, uuid, x, y, z, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz)
  select t.e, decode(md5('p' || t.e), 'hex'), t.x, t.y, t.z, floor(t.x / 16)::int, floor(t.z / 16)::int,
         round(t.x * 4096)::bigint, round(t.y * 4096)::bigint, round(t.z * 4096)::bigint
    from unnest(eids, xs, ys, zs) as t(e, x, y, z) $$;

-- Visible set, silently: a player at most 48 blocks away is at most 3 chunks away, so the (chunk_x, chunk_z) index finds every candidate.
create function mc.vis_init() returns bigint language plpgsql as $$
declare n bigint;
begin
    analyze mc.player;
    delete from mc.visible;
    insert into mc.visible (viewer_eid, target_eid)
    select a.eid, b.eid
      from mc.player a join mc.player b on b.chunk_x between a.chunk_x - 3 and a.chunk_x + 3 and b.chunk_z between a.chunk_z - 3 and a.chunk_z + 3
     where a.eid <> b.eid and (a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z) <= 2304.0;
    get diagnostics n = row_count;
    analyze mc.visible;
    return n / 2;
end $$;

create function mc.inbox_push(conns int[], payloads bytea[]) returns void language sql as $$
  insert into mc.inbox (conn, payload) select * from unnest(conns, payloads) $$;

create function mc.outbox_drain() returns table(conn int, data bytea) language sql as $$
  with d as (delete from mc.outbox returning seq, conn, data) select d.conn, d.data from d order by d.seq $$;

create function mc.visible_pairs() returns bigint language sql stable as $$ select count(*) / 2 from mc.visible $$;
create function mc.game_time() returns bigint language sql stable as $$ select game_time from mc.game_state $$;

create function mc.player_digest() returns bigint language sql stable as $$
  select coalesce(sum(eid::bigint * 1000003 + sent_qx * 7 + sent_qy * 13 + sent_qz * 17 + chunk_x::bigint * 31 + chunk_z::bigint * 37), 0)::bigint from mc.player $$;

------------------------------------------------------------------------------------------------ the tick
create function mc.server_tick() returns bigint language plpgsql as $$
declare
    tick  bigint;
    moved int;
    dummy int;
begin
    update mc.game_state set game_time = game_time + 1 returning game_time into tick;

    -- 1+2: parse, validate (conn known, |dx| <= 10 and |dz| <= 10 against the position before the tick), keep the last valid packet per conn, apply
    with inb as (delete from mc.inbox returning seq, conn, payload),
         dec as (select conn, seq, mc.f64be(payload, 1) as x, mc.f64be(payload, 9) as y, mc.f64be(payload, 17) as z,
                        mc.f32be(payload, 25) as yaw, mc.f32be(payload, 29) as pitch, (get_byte(payload, 33) & 1) = 1 as og from inb),
         ok  as (select distinct on (d.conn) d.* from dec d join mc.player p on p.eid = d.conn
                  where abs(d.x - p.x) <= 10 and abs(d.z - p.z) <= 10
                  order by d.conn, d.seq desc)
    update mc.player p
       set x = ok.x, y = ok.y, z = ok.z, yaw = ok.yaw, pitch = ok.pitch, on_ground = ok.og,
           chunk_x = floor(ok.x / 16)::int, chunk_z = floor(ok.z / 16)::int, last_move = tick
      from ok where p.eid = ok.conn;
    get diagnostics moved = row_count;

    if moved > 0 then
        -- 3+4: visibility diff of every pair with a mover (each pair once), movement fan-out to retained pairs, sent_q update
        with mv as materialized (
                select p.eid, p.x, p.y, p.z, p.yaw, p.pitch, p.on_ground, p.chunk_x as cx, p.chunk_z as cz, p.sent_qx, p.sent_qy, p.sent_qz
                  from mc.player p where p.last_move = tick),
             now_p as materialized (          -- pairs in range now (mover pe, other qe; both movers: only pe < qe)
                select m.eid as pe, q.eid as qe
                  from mv m join mc.player q on q.chunk_x between m.cx - 3 and m.cx + 3 and q.chunk_z between m.cz - 3 and m.cz + 3
                 where q.eid <> m.eid and (q.last_move <> tick or m.eid < q.eid)
                   and (m.x - q.x) * (m.x - q.x) + (m.z - q.z) * (m.z - q.z) <= 2304.0),
             was_p as materialized (          -- the same pairs as they were visible before the tick
                select m.eid as pe, v.target_eid as qe
                  from mv m join mc.visible v on v.viewer_eid = m.eid join mc.player q on q.eid = v.target_eid
                 where q.last_move <> tick or m.eid < q.eid),
             cls as materialized (
                select coalesce(n.pe, w.pe) as pe, coalesce(n.qe, w.qe) as qe, n.pe is not null as is_now, w.pe is not null as was
                  from now_p n full join was_p w on n.pe = w.pe and n.qe = w.qe),
             dir as materialized (            -- enter / leave, one row per direction (viewer sees target)
                select pe as viewer, qe as target, is_now from cls where is_now <> was
                union all
                select qe, pe, is_now from cls where is_now <> was),
             ins as (insert into mc.visible (viewer_eid, target_eid) select viewer, target from dir where is_now returning 1),
             del as (delete from mc.visible v using dir d where not d.is_now and v.viewer_eid = d.viewer and v.target_eid = d.target returning 1),
             padd as (insert into mc.outbox (conn, data)
                      select d.viewer, mc.pkt_add_entity(t.eid, t.uuid, t.x, t.y, t.z, t.yaw, t.pitch)
                        from dir d join mc.player t on t.eid = d.target where d.is_now returning 1),
             prem as (insert into mc.outbox (conn, data) select d.viewer, mc.pkt_remove_entity(d.target) from dir d where not d.is_now returning 1),
             mq as materialized (             -- one packet per mover, against what the other clients were last told
                select m.eid, round(m.x * 4096)::bigint as qx, round(m.y * 4096)::bigint as qy, round(m.z * 4096)::bigint as qz,
                       mc.pkt_move(m.eid, round(m.x * 4096)::bigint - m.sent_qx, round(m.y * 4096)::bigint - m.sent_qy, round(m.z * 4096)::bigint - m.sent_qz,
                                   m.x, m.y, m.z, m.yaw, m.pitch, m.on_ground) as pkt
                  from mv m),
             pmv as (insert into mc.outbox (conn, data)
                     select c.qe, mq.pkt from cls c join mq on mq.eid = c.pe where c.is_now and c.was
                     union all
                     select c.pe, mq.pkt from cls c join mq on mq.eid = c.qe where c.is_now and c.was
                     returning 1),
             upd as (update mc.player p set sent_qx = mq.qx, sent_qy = mq.qy, sent_qz = mq.qz from mq where p.eid = mq.eid returning 1)
        select 1 into dummy;
    end if;

    -- 5: block events in event-id order to every player within 8 chunks; one receiver set per distinct event chunk
    if exists (select 1 from mc.block_event) then
        with ev as (delete from mc.block_event returning id, kind, x, y, z, new_state, cnt),
             evp as materialized (
                select id, x >> 4 as ecx, z >> 4 as ecz,
                       case when kind = 'block' then mc.pkt_block_update(x, y, z, new_state) else mc.pkt_fill_update(x, y, z, new_state, cnt) end as pkt
                  from ev),
             ch as materialized (select distinct ecx, ecz from evp),
             rcv as materialized (
                select ch.ecx, ch.ecz, p.eid as conn from ch
                  join mc.player p on p.chunk_x between ch.ecx - 8 and ch.ecx + 8 and p.chunk_z between ch.ecz - 8 and ch.ecz + 8)
        insert into mc.outbox (conn, data)
        select r.conn, e.pkt from evp e join rcv r on r.ecx = e.ecx and r.ecz = e.ecz order by e.id, r.conn;
    end if;
    return tick;
end $$;

-- serverbound move_player_pos_rot (SPEC 6), for tests and drivers: 0x1d f64 x f64 y f64 z f32 yaw f32 pitch u8 flags
create function mc.move_payload(x float8, y float8, z float8, yaw float4, pitch float4, og boolean) returns bytea language sql immutable parallel safe as $$
  select '\x1d'::bytea || float8send(x) || float8send(y) || float8send(z) || float4send(yaw) || float4send(pitch) || set_byte('\x00'::bytea, 0, case when og then 1 else 0 end) $$;
