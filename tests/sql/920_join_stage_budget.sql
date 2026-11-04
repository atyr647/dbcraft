-- this test compares the join bursts of players who enter play in different ticks: with the vanilla tracker (sql/900) a later joiner's burst legitimately differs (waypoints of the players already there), so it runs with the classic broadcast
update mc.server_property set value = 'false' where key = 'dbcraft.vanilla-tracker';
-- The join stage budget (docs/PERF-STORM.md): the packet that makes a connection enter play is held back once the tick has used its time budget, and a joiner's chunk square
-- is sent over several ticks.  Driven through net.inbox and mc.server_tick() like a gateway, with clients that send each stage one tick after the previous.  Checked: budget
-- off = everything at once; budget on = one entry per tick (oldest connection first) and the others wait; a connection that has waited too long is never held back; what a
-- held-back joiner receives is byte for byte what it receives without the budget; the chunks of a larger square arrive in the same order, nearest first, whether they go out
-- in the join burst or in the following ticks.
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
-- sql/400 reinstalls the original hooks; put the login-path versions back on top of it (what a fresh migration ends with)
\ir ../../sql/460_join_codec.sql
\ir ../../sql/461_join_on_join.sql
\ir ../../sql/462_join_config_burst.sql
\ir ../../sql/430_chunk_queue.sql
\ir ../../sql/790_join_budget.sql
\ir ../../sql/791_join_chunk_budget.sql
\ir ../../sql/920_join_stage_budget.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py

------------------------------------------------------------------------------------------------ helpers
create table if not exists t.stream (conn_id bigint, tick int, data bytea);
create or replace function t.fresh() returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, net.join_parked;
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    truncate mc.chunk_request, mc.chunk_wanted, mc.chunk_wanted_view;
    delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
    perform mc.configure_dev_server('test', 'creative');
    update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
    update mc.server_property set value = '100' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
    update mc.server_property set value = 'off' where key = 'dbcraft.join-budget-ms';            -- the login gate is not under test here
    update mc.server_property set value = '49' where key = 'dbcraft.join-chunks-inline';
    update mc.server_property set value = '64' where key = 'dbcraft.chunk-batch-max';
    update mc.server_property set value = 'off' where key = 'dbcraft.tick-budget-ms';             -- the cap alone (the time-scaled cap has its own check below)
    update mc.server_property set value = '600' where key = 'dbcraft.chunk-budget-per-tick';
    update mc.server_property set value = '25' where key = 'dbcraft.join-entry-budget-ms';
    update mc.server_property set value = '1' where key = 'dbcraft.join-entry-free';
    update mc.game_state set game_time = 1, day_time = 1;
    perform setval('mc.entity_id_seq', 1, false);
    delete from mc.chunk where dimension = 'minecraft:overworld';
    drop table if exists t.stream;
    create table t.stream (conn_id bigint, tick int, data bytea);
end $$;
create or replace function t.stage(p_conn bigint, p_stage int, p_name text default null) returns void language plpgsql as $$
begin
    if p_stage = 1 then
        perform net.on_connect(p_conn);
        perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
        perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
    elsif p_stage = 2 then perform t.feed_pkt(p_conn, 'login', 'minecraft:login_acknowledged');
    elsif p_stage = 3 then perform t.feed_pkt(p_conn, 'configuration', 'minecraft:select_known_packs', proto.varint(0));
    else perform t.feed_pkt(p_conn, 'configuration', 'minecraft:finish_configuration');
    end if;
end $$;
-- one tick; every connection's output of that tick is appended to t.stream
create or replace function t.tick(p_n int) returns void language plpgsql as $$
begin
    update mc.game_state set game_time = 1, day_time = 1;      -- the world clock is in the join burst (set_time): hold it still
    delete from mc.tick_log; delete from mc.server_tick_log;   -- (so the tick numbers can repeat)
    perform mc.server_tick();
    insert into t.stream select c.conn_id, p_n, t.take(c.conn_id) from net.conn c;
end $$;
create or replace function t.nplay() returns int language sql stable as $$ select count(*)::int from net.conn where state = 'play' $$;
create or replace function t.burst_md5(p_conn bigint) returns text language plpgsql stable as $$      -- as tests/sql/790: bytes of the join burst up to its first chunk_batch_finished
declare b bytea; r text;
begin
    select string_agg(data, ''::bytea order by tick) into b from t.stream where conn_id = p_conn;
    with f as (select * from t.frames(b)),
         cut as (select min(idx) c from f where frame = '\x0103'::bytea),
         fin as (select min(f.idx) e from f, cut where f.idx > cut.c
                    and (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('play', 'clientbound', 'minecraft:chunk_batch_finished'))
    select md5(string_agg(f.frame, ''::bytea order by f.idx)) into r from f, fin where f.idx > 0 and f.idx <= fin.e;
    return r;
end $$;
-- all clients: stage 1 in tick 1, stage 2 in tick 2, stage 3 in tick 3, stage 4 in tick 4; then empty ticks 5 .. p_ticks
create or replace function t.run_logins(p_first int, p_n int, p_prefix text, p_ticks int) returns void language plpgsql as $$
declare i int;
begin
    for i in 1 .. p_ticks loop
        if i <= 4 then perform t.stage(c, i, p_prefix || c) from generate_series(p_first, p_first + p_n - 1) c; end if;
        perform t.tick(i);
    end loop;
end $$;
create or replace function t.chunk_md5s(p_conn bigint) returns text[] language plpgsql stable as $$      -- the chunk packets of a connection in the order received, as md5 of each
declare b bytea; r text[];
begin
    select string_agg(data, ''::bytea order by tick) into b from t.stream where conn_id = p_conn;
    select array_agg(md5(f.frame) order by f.idx) into r from t.frames(b) f
     where (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('play', 'clientbound', 'minecraft:level_chunk_with_light');
    return coalesce(r, '{}');
end $$;

------------------------------------------------------------------------------------------------ 1. entry budget off: all six connections enter play in the same tick
select t.fresh();
update mc.server_property set value = 'off' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(41, 6, 'Off', 4);
select t.eq('budget off: all six connections are in play after the tick of their finish_configuration', t.nplay(), 6);
create table t.md5_off as select c as conn_id, t.burst_md5(c) as h from generate_series(41, 46) c;
select t.is_true('...with a complete burst each', (select count(*) = 6 and bool_and(h is not null) from t.md5_off));

------------------------------------------------------------------------------------------------ 2. a budget that is always exhausted: the free entry of each tick, the others wait
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';           -- exhausted as soon as the tick has done anything
select t.run_logins(41, 6, 'Off', 4);
select t.eq('tick 4: one connection entered play (the free one), five wait', t.nplay(), 1);
select t.eq('...the five finish_configuration packets are back in net.inbox, order kept', (select array_agg(conn_id order by seq) from net.inbox), array[42, 43, 44, 45, 46]::bigint[]);
select t.is_true('...the oldest connection (lowest id) is the one that entered', (select state = 'play' from net.conn where conn_id = 41));
select t.tick(5);
select t.eq('tick 5: one more', t.nplay(), 2);
select t.is_true('...in connection order', (select state = 'play' from net.conn where conn_id = 42) and (select state = 'configuration' from net.conn where conn_id = 43));
select t.tick(6); select t.tick(7); select t.tick(8); select t.tick(9);
select t.eq('tick 9: all six are in play, one entry per tick', t.nplay(), 6);
select t.eq('...nothing left waiting', (select count(*)::int from net.inbox), 0);
create table t.md5_on as select c as conn_id, t.burst_md5(c) as h from generate_series(41, 46) c;
select t.is_true('every held-back joiner got a complete burst', (select count(*) = 6 and bool_and(h is not null) from t.md5_on));
select t.eq('...and the join burst of every one of the six is byte for byte the same as without the budget (entity ids, tab list, chunks, ...)',
            (select count(*)::int from t.md5_off o join t.md5_on n using (conn_id) where o.h is distinct from n.h), 0);

------------------------------------------------------------------------------------------------ 3. two free entries per tick; a connection that waited too long is never held back
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';
update mc.server_property set value = '2' where key = 'dbcraft.join-entry-free';
select t.run_logins(41, 6, 'Fr', 4);
select t.eq('two free entries per tick: two connections in play after tick 4', t.nplay(), 2);
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(41, 3, 'Od', 3);
update net.conn set connected_at = now() - interval '40 seconds' where conn_id = 43;              -- waited 40 s: past the maximum wait
select t.stage(c, 4) from generate_series(41, 43) c;
select t.tick(4);
select t.eq('tick 4: the free one (41) and the connection past its maximum wait (43) entered, 42 waits',
            (select array_agg(conn_id order by conn_id) from net.conn where state = 'play'), array[41, 43]::bigint[]);

select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(41, 8, 'Ov', 3);
update net.conn set connected_at = now() - interval '40 seconds';                                  -- all eight are past their maximum wait together (an overloaded machine)
select t.stage(c, 4) from generate_series(41, 48) c;
select t.tick(4);
select t.eq('eight connections past their maximum wait: the free one plus at most 3 overdue ones enter in a tick (no flood)', t.nplay(), 4);
select t.tick(5);
select t.eq('...4 more in the next tick: all eight are in', t.nplay(), 8);

------------------------------------------------------------------------------------------------ 4. what a held-back connection sends after its entry packet waits behind it
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(41, 2, 'Bh', 3);
select t.stage(c, 4) from generate_series(41, 42) c;
insert into net.inbox (conn_id, payload) values (42, proto.varint(net.pkt('play', 'serverbound', 'minecraft:client_tick_end')));      -- behind 42's entry packet
select t.tick(4);
select t.eq('42 is held with BOTH packets: the entry packet and the one behind it are in net.inbox again, in order',
            (select array_agg(conn_id order by seq) from net.inbox), array[42, 42]::bigint[]);
select t.tick(5);
select t.eq('next tick: nothing is left in net.inbox', (select count(*)::int from net.inbox), 0);
select t.eq('...and no error: ' || coalesce((select string_agg(step || ': ' || message, '; ') from mc.error_log), ''), (select count(*)::int from mc.error_log), 0);
select t.is_true('...42 is in play', (select state = 'play' from net.conn where conn_id = 42));

------------------------------------------------------------------------------------------------ 5. a larger square: the same chunk packets in the same order, in the join burst or in the following ticks
select t.fresh();
update mc.server_property set value = '4' where key in ('view-distance', 'simulation-distance');             -- 11 x 11 = 121 chunks
update mc.server_property set value = 'off' where key = 'dbcraft.join-entry-budget-ms';
update mc.server_property set value = '0' where key = 'dbcraft.join-chunks-inline';
select mc.generate_flat_area('minecraft:overworld', -8, -8, 8, 8) as made \gset
select t.run_logins(61, 1, 'Sq', 8);
create table t.sq_all as select t.chunk_md5s(61) as h, (select count(*)::int from t.stream where conn_id = 61 and tick = 4 and length(data) > 0) as ticks_with_data;
select t.eq('inline 0: all 121 chunk packets in the join burst', (select cardinality(h) from t.sq_all), 121);
select t.fresh();
update mc.server_property set value = '4' where key in ('view-distance', 'simulation-distance');
update mc.server_property set value = 'off' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(61, 1, 'Sq', 8);
create table t.sq_split as select t.chunk_md5s(61) as h;
select t.eq('inline 49: the join burst has 49 chunk packets, the rest (72) follows in later ticks: 121 in all',
            (select cardinality(h) from t.sq_split), 121);
select t.is_true('...the same packets in the same (nearest first) order as sending everything in the join', (select s.h = a.h from t.sq_split s, t.sq_all a));
select t.eq('...nothing left wanted', (select count(*)::int from mc.chunk_wanted), 0);
select t.eq('the first batch of the join holds exactly 49 chunks (chunk_batch_finished says so)',
            (select (proto.varint_read(substring(f.frame from (proto.varint_read(f.frame, 0)).nxt + 2), 0)).val
               from t.stream s, lateral t.frames(s.data) f
              where s.conn_id = 61 and (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('play', 'clientbound', 'minecraft:chunk_batch_finished')
              order by s.tick, f.idx limit 1), 49);

------------------------------------------------------------------------------------------------ 6. the delivery step with a large backlog
select t.fresh();
update mc.server_property set value = '4' where key in ('view-distance', 'simulation-distance');
select mc.generate_flat_area('minecraft:overworld', -8, -8, 8, 8) as made \gset
select t.player(c, 'Bk' || c) from generate_series(71, 74) c;
update net.conn set view_cx = 0, view_cz = 0 where conn_id between 71 and 74;
insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) select c, 'minecraft:overworld', dx, dz, dx * dx + dz * dz from generate_series(71, 74) c, generate_series(-5, 5) dx, generate_series(-5, 5) dz;
update mc.server_property set value = '100' where key = 'dbcraft.chunk-budget-per-tick';
select t.eq('a shared budget of 100 over 4 connections: 25 chunks each in the first tick (round-robin), 100 in all', mc.deliver_ready_chunks(), 100);
select t.eq('...the rows left are 4 x 121 - 100', (select count(*)::int from mc.chunk_wanted), 384);
select t.is_true('...everybody got the 25 nearest (the nearest 25 of the square have dist <= 8): none of the delivered rows is farther than every remaining one',
                 (select not exists (select 1 from mc.chunk_wanted w where w.dist < 8 and w.conn_id between 71 and 74 and w.dist <= 2)));
-- a client whose view moved: what left its square is dropped, the rest is delivered
update net.conn set view_cx = 3, view_cz = 0 where conn_id = 71;
select mc.deliver_ready_chunks();
select t.is_true('connection 71 moved 3 chunks east: nothing it still wants is outside its new square',
                 not exists (select 1 from mc.chunk_wanted w where w.conn_id = 71 and (abs(w.cx - 3) > 5 or abs(w.cz) > 5)));
-- a connection that is gone loses its rows
delete from net.conn where conn_id = 72;
select mc.deliver_ready_chunks();
select t.eq('connection 72 disconnected: its wanted rows are gone', (select count(*)::int from mc.chunk_wanted where conn_id = 72), 0);

------------------------------------------------------------------------------------------------ 7. the VarInt / waypoint packet speed-ups, byte for byte (docs/PERF-STORM.md)
-- the previous bodies, kept here as the reference
create or replace function proto.varint_slow_general(n int) returns bytea language sql immutable parallel safe as $$
  select case
    when u < 128        then set_byte('\x00'::bytea, 0, u::int)
    when u < 16384      then set_byte(set_byte('\x0000'::bytea, 0, ((u & 127) | 128)::int), 1, (u >> 7)::int)
    when u < 2097152    then set_byte(set_byte(set_byte('\x000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (u >> 14)::int)
    when u < 268435456  then set_byte(set_byte(set_byte(set_byte('\x00000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (((u >> 14) & 127) | 128)::int), 3, (u >> 21)::int)
    else set_byte(set_byte(set_byte(set_byte(set_byte('\x0000000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (((u >> 14) & 127) | 128)::int), 3, (((u >> 21) & 127) | 128)::int), 4, (u >> 28)::int)
  end
  from (select n::bigint & 4294967295 as u) s $$;
create or replace function mc.wp_body_general(p_op int, p_uuid uuid, p_kind int, p_a int, p_b int, p_c int, p_ang real) returns bytea language sql immutable parallel safe as $$
  select proto.varint(p_op) || '\x01'::bytea || proto.uuid(p_uuid) || proto.string('minecraft:default') || '\x00'::bytea
         || case p_kind when 1 then proto.varint(1) || proto.varint(p_a) || proto.varint(p_b) || proto.varint(p_c)
                        when 2 then proto.varint(2) || proto.varint(p_a) || proto.varint(p_b)
                        when 3 then proto.varint(3) || proto.f32(p_ang)
                        else proto.varint(0) end $$;
create or replace function mc.vis_wp_pass_general(p_cur bigint, p_phase int, p_n int default null) returns void language plpgsql as $$
declare enabled boolean := mc.rule_bool('locator_bar', true); n int; cap int := coalesce(mc.prop_int('dbcraft.locator-bar-max-players'), 120);
begin
  n := coalesce(p_n, (select count(*)::int from mc.player where conn_id is not null));
  if n > cap then enabled := false; end if;
  if not enabled and not exists (select 1 from mc.wp) then return; end if;       -- off and nothing connected: nothing to do, not even the bookkeeping (the first pass after it comes back remakes what it needs)
  with pl as materialized (
    select p.entity_id as eid, p.conn_id, p.uuid, p.x, p.y, p.z, p.last_move_tick, p.wp_state as old_st, floor(p.x)::int as bx, floor(p.y)::int as by, floor(p.z)::int as bz, p.chunk_x as cx, p.chunk_z as cz,
           p.wp_bx, p.wp_by, p.wp_bz, p.wp_cx, p.wp_cz,
           case when p_phase = 2 then mc.wp_state_now(p) else p.wp_state end as st,
           coalesce(case when p.view_distance_req is null then 2 else greatest(2, least(p.view_distance_req, mc.prop_int('view-distance'))) end, 2) as vr
      from mc.player p where p.conn_id is not null),
  pr as materialized (
    select r.eid as rcv, r.conn_id as rconn, s.eid as src, s.uuid as suuid, s.bx, s.by, s.bz, s.cx as scx, s.cz as scz,
           (enabled and s.st is not null and (s.st & 1) = 1 and not ((coalesce(r.st, 0) & 2) = 0 and (s.st & 2) = 2)) as want,
           (sqrt((r.x - s.x) ^ 2 + (r.y - s.y) ^ 2 + (r.z - s.z) ^ 2)::real > 332::real) as far,
           (abs(s.cx - r.cx) <= r.vr and abs(s.cz - r.cz) <= r.vr) as vis,
           (abs(s.bx - coalesce(s.wp_bx, s.bx)) + abs(s.by - coalesce(s.wp_by, s.by)) + abs(s.bz - coalesce(s.wp_bz, s.bz))) as manh,
           greatest(abs(s.cx - coalesce(s.wp_cx, s.cx)), abs(s.cz - coalesce(s.wp_cz, s.cz))) as cheb,
           mc.wp_angle(r.x, r.z, s.x, s.z) as ang,
           ((p_phase = 1 and r.last_move_tick = p_cur) or (p_phase = 2 and (s.old_st is null or ((s.st & 1) = 1 and (s.old_st & 1) = 0)))) as may_create,      -- a missing connection is made when the receiver moves (updatePlayer) or when the source starts to transmit (trackWaypoint)
           w.kind as ok, w.ang as oang
      from pl r join pl s on s.eid <> r.eid left join mc.wp w on w.rcv = r.eid and w.src = s.eid),
  dc as materialized (
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
  if p_phase = 1 then
    update mc.player set wp_bx = floor(x)::int, wp_by = floor(y)::int, wp_bz = floor(z)::int, wp_cx = chunk_x, wp_cz = chunk_z
     where conn_id is not null and (wp_bx is distinct from floor(x)::int or wp_by is distinct from floor(y)::int or wp_bz is distinct from floor(z)::int or wp_cx is distinct from chunk_x or wp_cz is distinct from chunk_z);
  else
    update mc.player p set wp_state = mc.wp_state_now(p) where p.conn_id is not null and p.wp_state is distinct from mc.wp_state_now(p);
  end if;
end $$;

select t.eq('proto.varint_slow: 400,000 random and edge ints give the bytes of the previous (FROM subselect) body',
            (select count(*)::int from (select (random() * 4294967295 - 2147483648)::bigint::int v from generate_series(1, 400000)
                                         union all select x from unnest(array[0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 268435456, 2147483647, -1, -128, -129, -2147483648, 141, 143]) x) q
              where proto.varint_slow(v) is distinct from proto.varint_slow_general(v)), 0);
select t.eq('mc.wp_body: 100,000 random packets of every kind and sign give the bytes of the previous body',
            (select count(*)::int from (select (random() * 3)::int op, (random() * 4)::int k, (random() * 4000000000 - 2000000000)::bigint::int a, (random() * 200000 - 100000)::int b,
                                               (random() * 600 - 300)::int c, (random() * 6.28)::real ang, gen_random_uuid() u from generate_series(1, 100000)) q
              where mc.wp_body(op, u, k, a, b, c, ang) is distinct from mc.wp_body_general(op, u, k, a, b, c, ang)), 0);
select t.eq('a waypoint frame (packet id 141, a two-byte VarInt) is framed as before',
            mc.pkt_waypoint(0, '8c5a0f4e-1111-2222-3333-444455556666', 3, 0, 0, 0, 0.5::real),
            proto.frame(141, mc.wp_body_general(0, '8c5a0f4e-1111-2222-3333-444455556666', 3, 0, 0, 0, 0.5::real)));

------------------------------------------------------------------------------------------------ 8. the locator bar's entity-phase pass looks at changed pairs only, and ends its connections in slices when it is off
create or replace function t.wp_build(p_seed float8, p_n int) returns void language plpgsql as $$
begin
  perform setseed(p_seed);
  update mc.game_rule set value = 'true' where name = 'minecraft:locator_bar';
  update mc.server_property set value = '120' where key = 'dbcraft.locator-bar-max-players';
  truncate mc.play_out, mc.wp; delete from mc.player;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode, last_move_tick)
  select md5(p_seed::text || i)::uuid, 'w' || i, i, 700 + i, cx * 16 + 8, 64, cz * 16 + 8, cx, cz, 1, 0
    from (select i, (random() * 40 - 10)::int as cx, (random() * 40 - 10)::int as cz from generate_series(1, p_n) i) g;
  update mc.player set wp_state = null;
  perform mc.vis_wp_pass_general(1000, 2, p_n);            -- everybody is new: every pair is connected, the states are remembered
  perform mc.vis_wp_pass_general(1001, 1, p_n);
  truncate mc.play_out;
  -- what changes: some crouch, some become spectators, some hide, a few arrive (state never seen), a few leave
  update mc.player set pose = 5 where random() < 0.15;
  update mc.player set gamemode = 3 where random() < 0.1;
  update mc.player set wp_hidden = true where random() < 0.05;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode, last_move_tick)
  select md5(p_seed::text || 'n' || i)::uuid, 'n' || i, 500 + i, 900 + i, cx * 16 + 8, 64, cz * 16 + 8, cx, cz, 1, 1001
    from (select i, (random() * 40 - 10)::int as cx, (random() * 40 - 10)::int as cz from generate_series(1, 3) i) g;
  update mc.player set conn_id = null where entity_id in (select entity_id from mc.player where random() < 0.03 and entity_id < 900);
end $$;
create or replace function t.wp_digest() returns jsonb language sql as $$
  select jsonb_build_object(
    'out',   (select coalesce(string_agg(conn_id || ':' || md5(d), ',' order by conn_id), '') from (select conn_id, string_agg(encode(data, 'hex'), '|' order by seq) d from mc.play_out group by conn_id) q),
    'wp',    (select coalesce(string_agg(rcv || '>' || src || '=' || kind || '/' || coalesce(ang::text, ''), ',' order by rcv, src), '') from mc.wp),
    'state', (select coalesce(string_agg(entity_id || '=' || coalesce(wp_state::text, 'n') || '/' || coalesce(wp_bx::text, 'n'), ',' order by entity_id), '') from mc.player)) $$;
create or replace function t.wp_compare(p_seed float8, p_n int) returns text language plpgsql as $$
declare da jsonb; db jsonb; diff text; n int;
begin
  perform t.wp_build(p_seed, p_n);
  drop table if exists t_w_player, t_w_wp; create table t_w_player as select * from mc.player; create table t_w_wp as select * from mc.wp;
  perform mc.vis_wp_pass_general(1002, 2, p_n + 3); da := t.wp_digest();
  truncate mc.play_out, mc.wp; delete from mc.player; insert into mc.player select * from t_w_player; insert into mc.wp select * from t_w_wp;
  perform mc.vis_wp_pass(1002, 2, p_n + 3); db := t.wp_digest();
  select string_agg(a.key, ',') into diff from jsonb_each_text(da) a join jsonb_each_text(db) b using (key) where a.value is distinct from b.value;
  if (da->>'out') = '' then return 'scenario sent nothing'; end if;
  return coalesce('differs in: ' || diff, 'same');
end $$;
select t.eq('entity phase over changed pairs only: seed ' || s || ', 40 players, the same packets, connections and remembered states as the pass over every pair', t.wp_compare(s / 10.0, 40), 'same') from generate_series(1, 6) s;
select t.eq('...and with 12 players', t.wp_compare(0.77, 12), 'same');

-- the bar switched off with 30 connected players: 30 x 29 UNTRACKs, ended 100 per pass; the packets of every receiver, in order, are those of one unsliced pass
select t.wp_build(0.3, 30);
update mc.server_property set value = '10' where key = 'dbcraft.locator-bar-max-players';          -- over the cap: the bar is off
update mc.server_property set value = '2000000000' where key = 'dbcraft.locator-bar-untrack-slice';
create temp table t_w_before as select * from mc.wp;
truncate mc.play_out;
select mc.vis_wp_pass_general(2000, 1, 33);
create temp table t_w_whole as select conn_id, md5(string_agg(data, ''::bytea order by seq)) h from mc.play_out group by conn_id;
select t.eq('the general pass (every pair evaluated) ends every connection between players that are online, at once, and leaves the rows of players that left',
            (select count(*)::int from mc.wp), (select count(*)::int from mc.wp w where not (exists (select 1 from mc.player p where p.entity_id = w.rcv and p.conn_id is not null) and exists (select 1 from mc.player p where p.entity_id = w.src and p.conn_id is not null))));
truncate mc.wp; insert into mc.wp select * from t_w_before; truncate mc.play_out;
update mc.server_property set value = '100' where key = 'dbcraft.locator-bar-untrack-slice';
select mc.vis_wp_pass(2000, 1, 33);
select t.eq('sliced: the first pass ended exactly 100 connections', (select count(*)::int from t_w_before) - (select count(*)::int from mc.wp), 100);
create temp table t_w_acc as select seq, conn_id, data from mc.play_out;
select mc.vis_wp_pass(2001 + g, 1, 33) from generate_series(1, 12) g;
select t.eq('...the remaining passes end the rest (and drop the rows of players that left)', (select count(*)::int from mc.wp), 0);
select t.eq('...and every receiver got the bytes of the general pass (every pair evaluated, one pass), in the same order',
            (select count(*)::int from (select conn_id, md5(string_agg(data, ''::bytea order by seq)) h from mc.play_out group by conn_id) s join t_w_whole w using (conn_id) where s.h = w.h), (select count(*)::int from t_w_whole));
update mc.server_property set value = '120' where key = 'dbcraft.locator-bar-max-players';
update mc.server_property set value = '1500' where key = 'dbcraft.locator-bar-untrack-slice';
truncate mc.play_out, mc.wp; delete from mc.player;
select t.fresh();
