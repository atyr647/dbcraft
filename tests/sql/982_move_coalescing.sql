-- The gateway merges several (position, client_tick_end) pairs of one connection and tick into the last position packet (gateway/src/gateway.rs coalesce_positions,
-- docs/PERF-CAPACITY.md).  This is the proof on the database side: a tick that is handed [P1, TE, P2, TE, P3] for a connection leaves EXACTLY the state, the output and the kicks of a tick that is handed
-- [P3] (what the gateway sends) or [TE, TE, P3] (the same with skip_tick_end off), for position-only and for position-and-rotation packets, with the vanilla tracker and with the classic
-- broadcast.  Connections that must not be merged (a violation: two positions without a client_tick_end between them; a NaN) get the same frames in every form and are kicked in all of them.
create or replace function t.mc_build(p_tracker boolean) returns void language plpgsql as $$
begin
  update mc.server_property set value = p_tracker::text where key = 'dbcraft.vanilla-tracker';
  update mc.server_property set value = '4' where key = 'view-distance';
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
           mc.block_event, mc.chunk_wanted, net.auth_result, net.join_parked, mc.server_tick_log, mc.tick_log, mc.error_log, mc.chat_log, mc.vtrk, mc.wp;
  delete from mc.player;
  update mc.game_state set game_time = 98;
  perform setseed(0.37);
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(g::text)::uuid, 'mover' || g, g, g, px, 70, pz, 0, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(70), mc.quant(pz), 0, 0, true, 0, 1, 98
    from (select g, random() * 60 as px, random() * 60 as pz from generate_series(1, 60) g) q;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
  select conn_id, 'play', name, uuid, -1, entity_id, chunk_x, chunk_z, gamemode from mc.player;
  perform mc.refresh_visibility();
  for i in 1 .. 2 loop perform mc.server_tick(); end loop;                   -- the first synchronisation of the tracker is over
  truncate net.outbox, net.inbox, net.play_inbox, mc.play_out, mc.server_tick_log, mc.tick_log, mc.error_log, mc.chat_log;
  update mc.game_state set game_time = 100;
  update mc.player set keepalive_sent_tick = 100;
end $$;

-- the frames of one connection: class 0 = pairs of position packets (the last one is what counts), 1 = pairs of position-and-rotation packets, 2 = a violation (two positions in a row, never merged),
-- 3 = a NaN in an early packet (kicked), 4 = a single position, 5 = a jump over 10 blocks in the last packet (moved too quickly: corrected), 6 = nothing
-- p_form: 0 as the client sent it, 1 merged by the gateway (the last position only), 2 merged with the tick ends left in front
create or replace function t.mc_frames(p_form int) returns void language plpgsql as $$
declare r record; cls int; n int; k int; i_pos int := mc.sid('move_player_pos'); i_pr int := mc.sid('move_player_pos_rot'); i_te int := mc.sid('client_tick_end');
        x0 float8; fl int; yw real; te_last boolean; pk bytea[]; te bytea := proto.varint(i_te);
begin
  perform setseed(0.71);
  for r in select * from mc.player order by conn_id loop
    cls := r.conn_id % 7; n := 2 + (random() * 3)::int; te_last := random() < .5; pk := '{}';
    for k in 1 .. n loop             -- every random number is drawn whatever the form, so the packets are the same in all of them
      fl := (random() < .5)::int; yw := (r.yaw + k * 7)::real; x0 := r.x + 0.2 * k;
      if cls = 3 and k = 1 then x0 := 'NaN'; end if;
      if cls = 5 and k = n then x0 := r.x + 25; end if;
      pk := pk || case when cls = 1 then proto.varint(i_pr) || proto.f64(x0) || proto.f64(r.y) || proto.f64(r.z + 0.1 * k) || proto.f32(yw) || proto.f32(r.pitch) || set_byte('\x00'::bytea, 0, fl)
                       else proto.varint(i_pos) || proto.f64(x0) || proto.f64(r.y) || proto.f64(r.z + 0.1 * k) || set_byte('\x00'::bytea, 0, fl) end;
    end loop;
    if cls = 4 then pk := pk[1:1]; end if;                                        -- a single position
    if cls = 2 then pk := pk[1:3]; end if;                                        -- a violation: three in a row, then a tick end
    if cls = 6 then pk := '{}'; end if;
    if cls in (0, 1, 5) and p_form = 1 then                                       -- merged by the gateway: the last position only
      insert into net.inbox (conn_id, payload) values (r.conn_id, pk[n]);
    elsif cls in (0, 1, 5) and p_form = 2 then                                    -- ... with the tick ends that were between the positions left in front
      for k in 1 .. n - 1 loop insert into net.inbox (conn_id, payload) values (r.conn_id, te); end loop;
      insert into net.inbox (conn_id, payload) values (r.conn_id, pk[n]);
    else                                                                          -- as the client sent it: (position, tick end) pairs, the last tick end sometimes missing
      for k in 1 .. coalesce(cardinality(pk), 0) loop
        insert into net.inbox (conn_id, payload) values (r.conn_id, pk[k]);
        if cls <> 2 and (k < cardinality(pk) or te_last) then insert into net.inbox (conn_id, payload) values (r.conn_id, te); end if;
        if cls = 2 and k = cardinality(pk) then insert into net.inbox (conn_id, payload) values (r.conn_id, te); end if;
      end loop;
    end if;
  end loop;
end $$;

create or replace function t.mc_digest() returns text language sql as $$
  select md5(string_agg(x, '|' order by k)) from (
    select 'p' || uuid::text as k, (to_jsonb(p) - 'keepalive_sent_tick')::text as x from mc.player p
    union all select 'v' || viewer_eid || '-' || target_eid, 'v' from mc.visible
    union all select 'o' || conn_id, encode(string_agg(data, ''::bytea order by seq), 'hex') from net.outbox group by conn_id
    union all select 'k' || conn_id, encode(reason_nbt, 'hex') from mc.kick
    union all select 'c' || conn_id, (to_jsonb(c) - 'last_activity' - 'connected_at')::text from net.conn c
    union all select 'e' || id, message from mc.error_log
    union all select 'w' || count(*), '' from mc.play_in_work) q $$;

create or replace function t.mc_run(p_tracker boolean, p_form int) returns text language plpgsql as $$
begin
  perform t.mc_build(p_tracker);
  perform t.mc_frames(p_form);
  perform mc.server_tick();
  return t.mc_digest();
end $$;

select t.mc_run(true, 0) is not null as ran;
select t.is_true('the scenario is not empty: most connections moved, packets went out, connections of classes 2 and 3 were kicked',
                 (select count(*) from mc.player where last_move_tick = (select game_time from mc.game_state)) > 20 and (select count(*) from net.outbox) > 0 and (select count(*) from net.conn where closing) >= 4);
select t.eq('tracker on: pairs merged by the gateway == the packets of the client', t.mc_run(true, 1), t.mc_run(true, 0));
select t.eq('tracker on: ...also with the tick ends left in front (skip_tick_end off)', t.mc_run(true, 2), t.mc_run(true, 0));
select t.eq('classic broadcast: pairs merged by the gateway == the packets of the client', t.mc_run(false, 1), t.mc_run(false, 0));
select t.eq('classic broadcast: ...also with the tick ends left in front', t.mc_run(false, 2), t.mc_run(false, 0));
-- mutation check of the test itself: a merge that picks the FIRST position instead of the last is detected
create or replace function t.mc_wrong() returns text language plpgsql as $$
begin
  perform t.mc_build(true);
  perform t.mc_frames(0);
  delete from net.inbox i using (select conn_id, max(seq) as s from net.inbox where payload < '\x20' group by conn_id) m where i.conn_id = m.conn_id and i.seq = m.s and i.conn_id % 7 = 0;   -- the last frame of the class-0 connections is lost
  perform mc.server_tick();
  return t.mc_digest();
end $$;
select t.is_true('the comparison detects a merge that loses the last position (mutation of the test)', t.mc_wrong() <> t.mc_run(true, 0));
