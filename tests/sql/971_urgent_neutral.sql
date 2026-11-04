-- sql/971: which kinds may stand ahead of a chat without keeping the urgent lane from handling it.  Proved here:
--   1. every serverbound play kind of the protocol is classified: neutral (net.urgent_neutral_play_ids), a barrier or a chat kind, or "not yet": a protocol update that adds a kind fails here until
--      someone decides; the neutral list contains what real clients send during play and none of the chat, command or text-input kinds;
--   2. for EVERY neutral kind, with several bodies (empty, short, the right shape where the tick parses one): the frames [kind..., chat, another player's chat] sent through the tick, and
--      through the lane (the chats between ticks, the other frames with the tick that follows), leave the same state (every column of every player, the connections, the chat log, kicks,
--      the clock, the errors) and send every connection the same set of frames (the order inside a recipient's stream may differ: the chat comes first now, it came after the
--      tick's movement and block packets before; it still comes in the order of its sender's chats and in the order of arrival between chats);
--   3. real traffic: several kinds from several players ahead of several chats, mixed (what a client in play really sends in 50 ms), same comparison;
--   4. mutation check of the test itself: a deliberately dependent kind (a stand-in handler that changes the sender's name before the chat is built) IS detected.
create or replace function t.un_build(p_n int) returns void language plpgsql as $$
begin
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
           mc.block_event, mc.chunk_wanted, net.auth_result, net.join_parked, mc.server_tick_log, mc.tick_log, mc.error_log, mc.chat_log;
  delete from mc.player;
  perform setseed(0.41);
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(g::text)::uuid, 'talker' || g, g, g, px, 70, pz, 0, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(70), mc.quant(pz), 0, 0, true, 0, 1, 0
    from (select g, random() * 30 as px, random() * 30 as pz from generate_series(1, p_n) g) q;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
  select conn_id, 'play', name, uuid, case when conn_id = 3 then 256 else -1 end, entity_id, chunk_x, chunk_z, gamemode from mc.player;
  perform mc.refresh_visibility();
  truncate mc.play_out;
  update mc.game_state set game_time = 100;
  update mc.player set keepalive_sent_tick = 100;
end $$;
create or replace function t.un_pid(p_name text) returns bytea language sql as $$ select proto.varint(net.pkt('play', 'serverbound', 'minecraft:' || p_name)) $$;
create or replace function t.un_chat(p_text text) returns bytea language sql as $$
  select t.un_pid('chat') || proto.string(p_text) || proto.i64(1000) || proto.i64(7) || '\x00' || proto.varint(0) || '\x000000' || '\x00' $$;
-- bodies: 0 empty, 1 eight zero bytes, 2 the right shape where the tick parses one
create or replace function t.un_body(p_name text, p_variant int) returns bytea language plpgsql as $$
begin
  if p_variant = 0 then return '\x'; end if;
  if p_variant = 1 then return '\x0000000000000000'; end if;
  return case p_name
    when 'client_information' then proto.string('en_us') || '\x0a' || proto.varint(0) || '\x01' || '\x7f' || proto.varint(1) || '\x00' || '\x01' || proto.varint(0)
    when 'set_carried_item' then '\x0003'
    when 'set_creative_mode_slot' then '\x002400'
    when 'player_command' then proto.varint(1) || proto.varint(1) || proto.varint(0)
    when 'player_input' then '\x41'
    when 'punch' then proto.varint(0)
    when 'keep_alive' then proto.i64(12345)
    when 'accept_teleportation' then '\x07'
    when 'chunk_batch_received' then proto.f32(7)
    when 'player_action' then proto.varint(0) || proto.position(5, 69, 5) || '\x01' || proto.varint(1)
    when 'use_item_on' then proto.varint(0) || proto.position(5, 69, 5) || proto.varint(1) || proto.f32(0.5) || proto.f32(1) || proto.f32(0.5) || '\x00' || '\x00' || proto.varint(2)
    when 'use_item' then proto.varint(0) || proto.varint(1) || proto.f32(0) || proto.f32(0)
    when 'client_command' then proto.varint(1)
    when 'move_player_pos' then proto.f64(3) || proto.f64(70) || proto.f64(3) || '\x01'
    when 'move_player_pos_rot' then proto.f64(3) || proto.f64(70) || proto.f64(3) || proto.f32(10) || proto.f32(5) || '\x01'
    when 'move_player_rot' then proto.f32(10) || proto.f32(5) || '\x01'
    when 'move_player_status_only' then '\x01'
    when 'custom_payload' then proto.string('minecraft:brand') || proto.string('vanilla')
    when 'container_close' then '\x00'
    when 'pong' then '\x00000007'
    else '\x0000' end;
end $$;
create or replace function t.un_digest() returns text language sql as $$
  select md5(coalesce((select string_agg(((to_jsonb(p) - 'first_seen') - 'last_seen')::text, '|' order by uuid) from mc.player p), '')
          || '#' || coalesce((select string_agg((((to_jsonb(c) - 'connected_at') - 'last_activity') - 'keepalive_sent')::text, '|' order by conn_id) from net.conn c), '')
          || '#' || coalesce((select string_agg(sender_name || ':' || message, '|' order by id) from mc.chat_log), '')
          || '#' || coalesce((select string_agg(conn_id::text, ',' order by conn_id) from mc.kick), '')
          || '#' || (select game_time from mc.game_state) || '#' || (select count(*) from mc.error_log)) $$;
create or replace function t.un_frames(b bytea) returns setof bytea language plpgsql as $$
declare o int := 0; v int; n int;
begin
    while o < length(b) loop
        select val, nxt into v, n from proto.varint_read(b, o);
        return next substring(b from o + 1 for (n - o) + v); o := n + v;
    end loop;
end $$;
create temp table un_out (path text, conn_id bigint, data bytea);
create temp table un_frames (ord int, conn bigint, payload bytea);
create or replace function t.un_collect(p_path text) returns void language plpgsql as $$
begin insert into un_out select p_path, conn_id, data from net.drain_outbox(); end $$;
-- per connection: the sorted frames of the path
create or replace function t.un_sets(p_path text) returns text language sql as $$
  select coalesce(string_agg(conn_id || ':' || fs, ',' order by conn_id), '') from (
    select conn_id, (select string_agg(md5(f), '/' order by md5(f)) from (select t.un_frames(string_agg(data, ''::bytea order by ctid)) f from un_out u2 where u2.path = p_path and u2.conn_id = u.conn_id) z) fs
      from (select distinct conn_id from un_out where path = p_path) u) q $$;
create or replace function t.un_is_chat(p bytea) returns boolean language sql as $$ select p like (t.un_pid('chat') || '%')::bytea $$;
create or replace function t.un_tick_path() returns text language plpgsql as $$
begin
  insert into net.inbox (conn_id, payload) select conn, payload from un_frames order by ord;
  perform mc.server_tick();
  perform t.un_collect('A');
  return t.un_digest();
end $$;
create or replace function t.un_lane_path(out digest text, out unhandled int[]) language plpgsql as $$
declare chat_conns bigint[]; chat_payloads bytea[]; chat_ords int[];
begin
  select array_agg(conn order by ord), array_agg(payload order by ord), array_agg(ord order by ord) into chat_conns, chat_payloads, chat_ords from un_frames where t.un_is_chat(payload);
  unhandled := net.urgent_chat(chat_conns, chat_payloads);
  perform t.un_collect('B');
  -- the frames the lane did not take (and every frame that is not a chat) go the normal way, in arrival order, with the tick that follows
  insert into net.inbox (conn_id, payload)
  select conn, payload from un_frames f
   where not t.un_is_chat(payload) or f.ord not in (select chat_ords[gs] from generate_subscripts(chat_ords, 1) gs where not (gs = any (unhandled))) order by ord;
  perform mc.server_tick();
  perform t.un_collect('B');
  digest := t.un_digest();
end $$;
create or replace function t.un_compare(p_name text) returns void language plpgsql as $$
declare da text; r record; sa text; sb text;
begin
  delete from un_out;
  perform t.un_build(6);
  da := t.un_tick_path();
  perform t.un_build(6);
  select * into r from t.un_lane_path();
  sa := t.un_sets('A'); sb := t.un_sets('B');
  if sa = '' then raise exception 'FAIL % : the tick sent nothing (empty comparison)', p_name; end if;
  if r.unhandled is distinct from '{}'::int[] then raise exception 'FAIL % : the lane handed back %', p_name, r.unhandled; end if;
  if sa <> sb then raise exception 'FAIL % : the frames differ (tick % lane %)', p_name, sa, sb; end if;
  if da <> r.digest then raise exception 'FAIL % : the state differs', p_name; end if;
  raise notice 'ok   %', p_name;
end $$;

------------------------------------------------------------------------------------------------ 1. every kind is classified
create temp table un_kinds (name text primary key, class text not null);
insert into un_kinds values
  ('chat', 'candidate'), ('chat_command', 'barrier'), ('chat_command_signed', 'barrier'),
  ('chat_ack', 'chat protocol'), ('chat_session_update', 'chat protocol'), ('command_suggestion', 'command tree'),
  ('change_difficulty', 'command in disguise'), ('change_game_mode', 'command in disguise'), ('lock_difficulty', 'command in disguise'), ('set_game_rule', 'command in disguise'),
  ('edit_book', 'text input'), ('sign_update', 'text input'), ('set_beacon', 'text input'), ('set_command_block', 'text input'), ('set_command_minecart', 'text input'),
  ('set_jigsaw_block', 'text input'), ('set_structure_block', 'text input'), ('set_test_block', 'text input'), ('test_instance_block_action', 'text input'), ('jigsaw_generate', 'text input'),
  ('configuration_acknowledged', 'state change'), ('custom_click_action', 'state change'),
  ('attack', 'entity interaction'), ('interact', 'entity interaction'), ('entity_tag_query', 'entity interaction'), ('teleport_to_entity', 'entity interaction'),
  ('spectator_action', 'entity interaction'), ('move_vehicle', 'entity interaction'), ('paddle_boat', 'entity interaction'), ('pick_item_from_entity', 'entity interaction'),
  ('select_trade', 'entity interaction'), ('bundle_item_selected', 'entity interaction'), ('block_entity_tag_query', 'entity interaction');
insert into un_kinds select substr(n, 11), 'neutral' from (select name as n from ref.packet where state = 'play' and direction = 'serverbound' and protocol_id = any (net.urgent_neutral_play_ids())) q;
select t.eq('every serverbound play kind is classified (a protocol update that adds one fails here: decide, then add it to net.urgent_neutral_play_ids or to this list)',
            (select coalesce(string_agg(substr(name, 11), ',' order by name), '') from ref.packet p where state = 'play' and direction = 'serverbound' and not exists (select 1 from un_kinds k where 'minecraft:' || k.name = p.name)), '');
select t.eq('...and nothing in the list is not a serverbound play kind', (select coalesce(string_agg(k.name, ','), '') from un_kinds k where not exists (select 1 from ref.packet p where p.state = 'play' and p.direction = 'serverbound' and p.name = 'minecraft:' || k.name)), '');
select t.is_true('the neutral list has no chat, command or text-input kind and has what real clients send',
  (select count(*) from un_kinds where class = 'neutral') between 30 and 45
  and not exists (select 1 from un_kinds where class = 'neutral' and name in ('chat', 'chat_command', 'chat_command_signed', 'chat_ack', 'chat_session_update', 'command_suggestion'))
  and (select count(*) from un_kinds where class = 'neutral' and name in ('player_input', 'punch', 'player_command', 'client_information', 'chunk_batch_received', 'keep_alive', 'pong', 'custom_payload',
        'client_tick_end', 'move_player_pos', 'move_player_pos_rot', 'move_player_rot', 'move_player_status_only', 'accept_teleportation', 'player_loaded', 'set_carried_item', 'player_action', 'use_item_on')) = 18);

------------------------------------------------------------------------------------------------ 2. one kind at a time, three bodies each
create or replace function t.un_one_kind(p_name text) returns void language plpgsql as $$
declare v int; o int := 0;
begin
  delete from un_frames;
  for v in 0 .. 2 loop
    o := o + 1; insert into un_frames values (o, 1, t.un_pid(p_name) || t.un_body(p_name, v));
  end loop;
  o := o + 1; insert into un_frames values (o, 2, t.un_pid(p_name) || t.un_body(p_name, 2));
  o := o + 1; insert into un_frames values (o, 1, t.un_chat('hello after ' || p_name));
  o := o + 1; insert into un_frames values (o, 2, t.un_chat('and a reply'));
  o := o + 1; insert into un_frames values (o, 3, t.un_chat('from the compressing connection'));
  perform t.un_compare('neutral kind ' || p_name || ': tick and lane agree (state and frames)');
end $$;
select t.un_one_kind(name) from un_kinds where class = 'neutral' order by name;

------------------------------------------------------------------------------------------------ 3. mixed traffic
create or replace function t.un_mixed(p_seed int) returns void language plpgsql as $$
declare names text[] := array(select name from un_kinds where class = 'neutral' order by name); o int := 0; i int; c int; k text; n int := array_length(names, 1);
begin
  delete from un_frames;
  perform setseed(p_seed / 100.0);
  for i in 1 .. 40 loop
    c := 1 + floor(random() * 5)::int;
    if random() < 0.35 then
      o := o + 1; insert into un_frames values (o, c, t.un_chat('seed ' || p_seed || ' message ' || i));
    else
      k := names[1 + floor(random() * n)::int];
      o := o + 1; insert into un_frames values (o, c, t.un_pid(k) || t.un_body(k, floor(random() * 3)::int));
    end if;
  end loop;
  perform t.un_compare('mixed traffic, seed ' || p_seed || ': tick and lane agree');
end $$;
select t.un_mixed(s) from generate_series(1, 8) s;

------------------------------------------------------------------------------------------------ 4. the test can fail: a kind that DOES change what the chat does
-- a stand-in for a future handler: after the tick's movement the sender is renamed; the chat of the same window is built after that in the tick and before it in the lane
create or replace function t.un_dependent_kind() returns text language plpgsql as $$
declare da text; db text; sa text; sb text;
begin
  delete from un_out; delete from un_frames;
  insert into un_frames values (1, 1, t.un_pid('player_input') || '\x41'), (2, 1, t.un_chat('who am i')), (3, 2, t.un_chat('and you'));
  perform t.un_build(6);
  insert into net.inbox (conn_id, payload) select conn, payload from un_frames order by ord;
  update mc.player set name = 'renamed' where conn_id = 1;             -- "the handler ran first" (what the tick would do before apply_chat)
  perform mc.server_tick(); perform t.un_collect('A'); da := t.un_digest(); sa := t.un_sets('A');
  perform t.un_build(6);
  perform net.urgent_chat((select array_agg(conn order by ord) from un_frames where t.un_is_chat(payload)), (select array_agg(payload order by ord) from un_frames where t.un_is_chat(payload)));
  perform t.un_collect('B');
  update mc.player set name = 'renamed' where conn_id = 1;             -- ... and in the lane it runs after the chat
  insert into net.inbox (conn_id, payload) select conn, payload from un_frames where not t.un_is_chat(payload) order by ord;
  perform mc.server_tick(); perform t.un_collect('B'); db := t.un_digest(); sb := t.un_sets('B');
  return case when sa <> sb or da <> db then 'detected' else 'MISSED' end;
end $$;
select t.eq('a kind that changes the sender before its chat is built makes the two paths differ (the comparison can fail)', t.un_dependent_kind(), 'detected');
