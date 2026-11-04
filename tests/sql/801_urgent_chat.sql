-- sql/801: the urgent chat lane.  net.urgent_chat handles serverbound chat frames between ticks; what it sends must be byte for byte what the tick sends for the same frames.
--   A. the tick path: frames into net.inbox, mc.server_tick(), net.drain_outbox();  B. the lane: net.urgent_chat(frames), net.drain_outbox(), then an ordinary tick with an empty inbox.
--   Both start from the same state; the bytes every connection receives (A: the tick's; B: the lane's followed by the tick's) and the state of the players must be equal.
--   Also: which frames the lane hands back, that nothing is taken twice, and that a connection's frames are never reordered.
create or replace function t.uc_build(p_n int) returns void language plpgsql as $$
begin
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
           mc.block_event, mc.chunk_wanted, net.auth_result, net.join_parked, mc.server_tick_log, mc.tick_log, mc.error_log, mc.chat_log;
  delete from mc.player;
  perform setseed(0.31);
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(g::text)::uuid, 'chatter' || g, g, g, px, 70, pz, 0, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(70), mc.quant(pz), 0, 0, true, 0, 1, 0
    from (select g, random() * 30 as px, random() * 30 as pz from generate_series(1, p_n) g) q;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
  select conn_id, case when conn_id = p_n then 'configuration' else 'play' end, name, uuid, case when conn_id = 3 then 256 else -1 end, entity_id, chunk_x, chunk_z, gamemode from mc.player;
  perform mc.refresh_visibility();
  truncate mc.play_out;
  update mc.game_state set game_time = 100;           -- the next tick is 101: no time packet (every 20th), no keep-alive due (a player's last was sent at tick 0, 300 ticks)
  update mc.player set keepalive_sent_tick = 100;
end $$;
create or replace function t.uc_chat(p_text text, p_ts bigint default 1000) returns bytea language sql as $$
  select proto.varint(net.pkt('play', 'serverbound', 'minecraft:chat')) || proto.string(p_text) || proto.i64(p_ts) || proto.i64(7) || '\x00' || proto.varint(0) || '\x000000' || '\x00' $$;
create or replace function t.uc_digest() returns text language sql as $$
  select md5(coalesce((select string_agg(p::text, '|' order by uuid) from (select uuid, conn_id, chat_sent, chat_recv, awaiting_teleport, vis_dirty, keepalive_id from mc.player) p), '')
          || '#' || (select count(*) from mc.chat_log) || '#' || coalesce((select string_agg(sender_name || ':' || message, '|' order by id) from mc.chat_log), '')
          || '#' || (select count(*) from mc.kick) || '#' || coalesce((select string_agg(conn_id::text, ',' order by conn_id) from mc.kick), '')) $$;
create temp table uc_out (path text, conn_id bigint, data bytea);
create or replace function t.uc_collect(p_path text) returns void language plpgsql as $$
begin
  insert into uc_out select p_path, conn_id, data from net.drain_outbox();
end $$;
-- frames: (conn, payload) in arrival order
create temp table uc_frames (ord int, conn bigint, payload bytea);
create or replace function t.uc_run_tick(p_path text) returns text language plpgsql as $$
begin
  insert into net.inbox (conn_id, payload) select conn, payload from uc_frames order by ord;
  perform mc.server_tick();
  perform t.uc_collect(p_path);
  return t.uc_digest();
end $$;
create or replace function t.uc_run_lane(p_path text, out digest text, out unhandled int[]) language plpgsql as $$
begin
  unhandled := net.urgent_chat((select array_agg(conn order by ord) from uc_frames), (select array_agg(payload order by ord) from uc_frames));
  perform t.uc_collect(p_path);
  -- what the lane did not take goes the normal way, in order, with the ordinary tick that follows
  insert into net.inbox (conn_id, payload) select conn, payload from uc_frames where ord = any (unhandled) order by ord;
  perform mc.server_tick();
  perform t.uc_collect(p_path);
  digest := t.uc_digest();
end $$;
create or replace function t.uc_streams(p_path text) returns text language sql as $$
  select coalesce(string_agg(conn_id || ':' || md5(s), ',' order by conn_id), '') from (select conn_id, string_agg(encode(data, 'hex'), '' order by ctid) s from uc_out where path = p_path group by conn_id) q $$;
create or replace function t.uc_compare(p_name text, p_expect_unhandled int[]) returns void language plpgsql as $$
declare da text; r record; sa text; sb text;
begin
  delete from uc_out;
  perform t.uc_build(6);
  da := t.uc_run_tick('A');
  perform t.uc_build(6);
  select * into r from t.uc_run_lane('B');
  sa := t.uc_streams('A'); sb := t.uc_streams('B');
  if sa = '' then raise exception 'FAIL % : the tick sent nothing (empty comparison)', p_name; end if;
  if sa <> sb then raise exception 'FAIL % : the bytes differ (tick % lane %)', p_name, sa, sb; end if;
  if da <> r.digest then raise exception 'FAIL % : the state differs', p_name; end if;
  if r.unhandled is distinct from p_expect_unhandled then raise exception 'FAIL % : handed back % want %', p_name, r.unhandled, p_expect_unhandled; end if;
  raise notice 'ok   %', p_name;
end $$;

insert into uc_frames values (1, 1, t.uc_chat('hello')), (2, 2, t.uc_chat('hi there')), (3, 1, t.uc_chat('second from one')), (4, 4, t.uc_chat('x'));
select t.uc_compare('four chats from three players: same bytes, same state, nothing handed back', '{}');
select t.is_true('...a connection with compression got its frames re-framed (and the bytes are equal)', exists (select 1 from uc_out where path = 'B' and conn_id = 3));

delete from uc_frames;
insert into uc_frames values (1, 1, t.uc_chat('first')), (2, 2, t.uc_chat('')), (3, 2, t.uc_chat('after the empty one')), (4, 5, t.uc_chat('bad' || chr(7))), (5, 3, t.uc_chat('from the compressing one'));
select t.uc_compare('an empty message and an illegal character (kick) behave as in the tick', '{}');
select t.is_true('...the illegal character kicked connection 5 (it was sent its disconnect and closed)', exists (select 1 from uc_out where path = 'B' and conn_id = 5) and not exists (select 1 from net.conn where conn_id = 5));

delete from uc_frames;
insert into uc_frames values (1, 1, t.uc_chat('from a player')), (2, 6, t.uc_chat('from a connection that is not in play')), (3, 6, t.uc_chat('and its second one')),
  (4, 99, t.uc_chat('from nobody')), (5, 2, proto.varint(net.pkt('play', 'serverbound', 'minecraft:client_tick_end'))), (6, 2, t.uc_chat('after a tick end'));
select t.uc_compare('frames the lane must not take are handed back (not in play, unknown, not chat) and a handed-back frame holds back the later ones of its connection', '{2,3,4,5,6}');

delete from uc_frames;
insert into uc_frames values (1, 1, t.uc_chat('a')), (2, 1, t.uc_chat('b')), (3, 1, t.uc_chat('c')), (4, 2, t.uc_chat('d')), (5, 1, t.uc_chat('e')), (6, 2, t.uc_chat('f'));
select t.uc_compare('six chats from two players keep their order and their per-sender indices', '{}');
select t.is_true('...in the order of arrival', (select string_agg(message, '' order by id) from mc.chat_log) = 'abcdef');

-- the lane with nothing to take, and with an empty list, changes nothing
select t.uc_build(3);
select t.eq('no frames: nothing handed back', net.urgent_chat('{}'::bigint[], '{}'::bytea[]), '{}'::int[]);
select t.is_true('...and nothing queued', not exists (select 1 from mc.play_out) and not exists (select 1 from net.outbox) and not exists (select 1 from mc.play_in_work));

-- a command is never taken
delete from uc_frames;
insert into uc_frames values (1, 1, proto.varint(net.pkt('play', 'serverbound', 'minecraft:chat_command')) || proto.string('list'));
select t.uc_build(3);
select t.eq('a command frame is handed back', net.urgent_chat(array[1::bigint], array[(select payload from uc_frames where ord = 1)]), array[1]);
select t.is_true('...and nothing of it is queued', not exists (select 1 from mc.play_in_work) and not exists (select 1 from mc.play_out));

-- mc.drain_play_out is the tick's drain: the same bytes for a mixed queue (plain and compressing connections)
select t.uc_build(4);
insert into mc.play_out (conn_id, data) values (1, '\x0105'), (3, '\x0107'), (1, '\x0106'), (2, '\x0108'), (3, '\x0109');
select t.eq('drain_play_out returns the frames it moved', mc.drain_play_out(), 5);
select t.is_true('...in generation order per connection, compressing ones re-framed', (select count(*) from net.outbox where conn_id = 1) = 2 and (select count(*) from net.outbox where conn_id = 3) = 1);
select t.uc_build(2);
