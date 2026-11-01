-- join / leave / visibility / movement rules.  Expected bytes come from the packet builders, which tests/game_verify.py proves equal to the real server's.
create or replace function t.send(conn int, pname text, body bytea) returns void language sql as $$
  insert into mc.play_in_work (conn_id, packet_id, body) values (conn, mc.sid(pname), body) $$;
create or replace function t.pos(x float8, y float8, z float8, flags int default 1) returns bytea language sql as $$ select proto.f64(x) || proto.f64(y) || proto.f64(z) || proto.i8(flags) $$;
create or replace function t.pos_rot(x float8, y float8, z float8, yaw real, pitch real, flags int default 1) returns bytea language sql as $$
  select proto.f64(x) || proto.f64(y) || proto.f64(z) || proto.f32(yaw) || proto.f32(pitch) || proto.i8(flags) $$;
create or replace function t.rot(yaw real, pitch real, flags int default 1) returns bytea language sql as $$ select proto.f32(yaw) || proto.f32(pitch) || proto.i8(flags) $$;
create or replace function t.out(conn int) returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = conn $$;
create or replace function t.reset() returns void language sql as $$ truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick $$;

select t.reset();
truncate mc.visible;
update mc.game_state set spawn_x = 0.5, spawn_y = 64, spawn_z = 0.5, spawn_yaw = 0;
update mc.server_property set value = '10' where key = 'view-distance';

------------------------------------------------------------------------------------------------ join
select mc.on_join(1, '00000000-0000-0000-0000-000000003301', 'P1');
select t.eq('first player gets a live entity id and conn', (select conn_id from mc.player where name = 'P1'), 1);
select t.eq('spawn position used for a new player', (select (x, y, z)::text from mc.player where name = 'P1'), '(0.5,64,0.5)');
select t.eq('alone: join message then own tab entry',
  t.out(1),
  mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.joined', array[mc.tc_player('00000000-0000-0000-0000-000000003301', 'P1')], 'yellow')))
  || mc.pkt_player_info_add(array[mc.pie_add('00000000-0000-0000-0000-000000003301', 'P1', 0)]));
select t.reset();
select mc.on_join(2, '00000000-0000-0000-0000-000000003302', 'P2');
select t.eq('P2 sees the join message, its own tab entry, and P1 in the tab list', t.out(2),
  mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.joined', array[mc.tc_player('00000000-0000-0000-0000-000000003302', 'P2')], 'yellow')))
  || mc.pkt_player_info_add(array[mc.pie_add('00000000-0000-0000-0000-000000003302', 'P2', 0)])
  || mc.pkt_player_info_add(array[mc.pie_add('00000000-0000-0000-0000-000000003301', 'P1', 0)]));
select t.eq('P1 sees P2 join (message + tab entry)', t.out(1),
  mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.joined', array[mc.tc_player('00000000-0000-0000-0000-000000003302', 'P2')], 'yellow')))
  || mc.pkt_player_info_add(array[mc.pie_add('00000000-0000-0000-0000-000000003302', 'P2', 0)]));
select t.is_true('entity ids differ', (select count(distinct entity_id) = 2 from mc.player where conn_id is not null));

------------------------------------------------------------------------------------------------ visibility
select t.reset();
select t.eq('refresh: two directed pairs added', (select added from mc.refresh_visibility()), 2);
select t.eq('visible rows are symmetric', (select count(*) from mc.visible)::int, 2);
select t.eq('P1 is told about P2 (add_entity at P2''s sent position)', t.out(1),
  mc.pkt_add_player_entity((select entity_id from mc.player where name = 'P2'), '00000000-0000-0000-0000-000000003302', 0.5, 64, 0.5, 0, 0, 0));
select t.eq('P2 is told about P1', t.out(2),
  mc.pkt_add_player_entity((select entity_id from mc.player where name = 'P1'), '00000000-0000-0000-0000-000000003301', 0.5, 64, 0.5, 0, 0, 0));
select t.is_true('dirty flags cleared', (select not bool_or(vis_dirty) from mc.player));
select t.eq('second refresh changes nothing', (select (added, removed)::text from mc.refresh_visibility()), '(0,0)');

------------------------------------------------------------------------------------------------ movement: broadcast
select t.reset();
select t.send(1, 'move_player_pos', t.pos(1.5, 64, 0.5));
select t.send(1, 'client_tick_end', '\x');
select t.eq('apply: one mover', (select moved from mc.apply_player_moves(10)), 1);
select t.eq('P1 moved', (select x from mc.player where name = 'P1'), 1.5::float8);
select t.eq('P2 receives a relative move of exactly one block (4096/4096) with 10 ticks since the last update', t.out(2),
  mc.pkt_move_entity_pos((select entity_id from mc.player where name = 'P1'), 4096, 0, 0, 10, true));
select t.eq('the mover itself receives nothing', t.out(1), '\x'::bytea);
select t.is_true('input consumed', not exists (select 1 from mc.play_in));

select t.reset();
select t.send(1, 'move_player_rot', t.rot(90, 10));
select t.send(1, 'client_tick_end', '\x');
select mc.apply_player_moves(11);
select t.eq('rotation only: move_entity_rot + rotate_head', t.out(2),
  mc.pkt_move_entity_rot((select entity_id from mc.player where name = 'P1'), 90, 10, true) || mc.pkt_rotate_head((select entity_id from mc.player where name = 'P1'), 90));

select t.reset();
select t.send(1, 'move_player_pos_rot', t.pos_rot(2.0, 64, 1.0, 180, -20));
select t.send(1, 'client_tick_end', '\x');
select mc.apply_player_moves(12);
select t.eq('position and rotation: move_entity_pos_rot + rotate_head', t.out(2),
  mc.pkt_move_entity_pos_rot((select entity_id from mc.player where name = 'P1'), 2048, 0, 2048, 1, 180, -20, true) || mc.pkt_rotate_head((select entity_id from mc.player where name = 'P1'), 180));

select t.reset();
select t.send(1, 'move_player_status_only', proto.i8(0));
select t.send(1, 'client_tick_end', '\x');
select mc.apply_player_moves(13);
select t.eq('status-only changes on_ground and sends nothing', t.out(2), '\x'::bytea);
select t.eq('on_ground updated', (select on_ground from mc.player where name = 'P1'), false);

select t.reset();
select t.send(1, 'move_player_pos', t.pos(2.0, 64, 1.0, 0));
select t.send(1, 'move_player_pos', t.pos(2.0, 64, 1.0, 0));  -- same position twice: would be no-op but still two packets in one tick
select mc.apply_player_moves(14);

------------------------------------------------------------------------------------------------ rules measured on the real server
-- (the previous step queued two position packets with no client_tick_end between them: the real server disconnects such a client)
select t.eq('two position packets in one client tick: kicked with invalid_player_movement', (select reason_nbt from mc.kick where conn_id = 1),
  proto.nbt_root(mc.disconnect_nbt('multiplayer.disconnect.invalid_player_movement')));
select t.eq('...and the disconnect packet was queued', t.out(1), mc.pkt_disconnect(proto.nbt_root(mc.disconnect_nbt('multiplayer.disconnect.invalid_player_movement'))));

select t.reset(); select t.send(2, 'move_player_pos', t.pos(0.5, 64, 0.5)); select t.send(2, 'client_tick_end', '\x'); select t.send(2, 'move_player_pos', t.pos(0.7, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(15);
select t.is_true('a tick_end between position packets keeps the client', not exists (select 1 from mc.kick where conn_id = 2));
select t.eq('last position of the batch wins', (select x from mc.player where name = 'P2'), 0.7::float8);

select t.reset(); select t.send(2, 'move_player_rot', t.rot(1, 1)); select t.send(2, 'move_player_rot', t.rot(2, 2)); select t.send(2, 'move_player_rot', t.rot(3, 3)); select t.send(2, 'move_player_status_only', proto.i8(1));
select mc.apply_player_moves(16);
select t.is_true('rotation-only and status-only packets are not limited per tick', not exists (select 1 from mc.kick where conn_id = 2));
select t.eq('last rotation wins', (select (yaw, pitch)::text from mc.player where name = 'P2'), '(3,3)');

select t.reset(); select t.send(2, 'move_player_pos', t.pos('NaN'::float8, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(17);
select t.is_true('NaN coordinate: kicked', exists (select 1 from mc.kick where conn_id = 2));
select t.eq('...position unchanged', (select x from mc.player where name = 'P2'), 0.7::float8);
select t.reset();

-- speed rule: 9.9 blocks accepted, 10.1 refused (a stationary player), then moves ignored until the teleport is confirmed
select t.send(2, 'move_player_pos', t.pos(0.7 + 9.9, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(18);
select t.eq('9.9 blocks in one packet is accepted', (select x from mc.player where name = 'P2'), 10.6::float8);
select t.send(2, 'move_player_pos', t.pos(0.7, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(19);                                   -- back to 0.7: that is a 9.9 block move too, accepted
select t.reset();
select t.send(2, 'move_player_pos', t.pos(0.7 + 10.1, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select t.eq('10.1 blocks: one correction', (select corrected from mc.apply_player_moves(20)), 1);
select t.eq('position not changed by the refused move', (select x from mc.player where name = 'P2'), 0.7::float8);
select t.eq('player_position carries a new teleport id, the old position and zero delta', t.out(2),
  mc.pkt_player_position(1, 0.7, 64, 0.5, 0, 0, 0, 3, 3, 0));
select t.eq('awaiting that teleport id', (select awaiting_teleport from mc.player where name = 'P2'), 1);
select t.reset();
select t.send(2, 'move_player_pos', t.pos(1.2, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(21);
select t.eq('moves are ignored while a teleport is unconfirmed', (select x from mc.player where name = 'P2'), 0.7::float8);
select t.send(2, 'accept_teleportation', proto.varint(1) || proto.f64(0.7) || proto.f64(64) || proto.f64(0.5) || proto.f32(3) || proto.f32(3));
select t.send(2, 'move_player_pos', t.pos(1.2, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(22);
select t.is_true('teleport confirmation clears the gate', (select awaiting_teleport is null from mc.player where name = 'P2'));
select t.eq('...and later moves apply', (select x from mc.player where name = 'P2'), 1.2::float8);

------------------------------------------------------------------------------------------------ chunk crossing and leaving
select t.reset();
select t.send(2, 'move_player_pos', t.pos(7.2, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(23);
select t.eq('moving within the view distance keeps visibility', (select (added, removed)::text from mc.refresh_visibility()), '(0,0)');
select t.is_true('chunk coordinates follow x (floor(x/16))', (select chunk_x = 0 from mc.player where name = 'P2'));
select t.reset();
select t.send(2, 'move_player_pos', t.pos(7.2 + 9, 64, 0.5)); select t.send(2, 'client_tick_end', '\x');
select mc.apply_player_moves(24);
select t.reset();
-- walk far away one legal step at a time (<10 blocks per packet)
do $$ declare i int; begin
  for i in 1..25 loop
    perform t.send(2, 'move_player_pos', t.pos(16.2 + 9 * i, 64, 0.5)); perform t.send(2, 'client_tick_end', '\x');
    perform mc.apply_player_moves(30 + i);
  end loop;
end $$;
select t.is_true('P2 walked more than 10 chunks away', (select abs(chunk_x) > 10 from mc.player where name = 'P2'));
select t.reset();
select t.eq('leaving the view distance removes both directed pairs', (select removed from mc.refresh_visibility()), 2);
select t.eq('P1 is told to forget P2', t.out(1), mc.pkt_remove_entities(array[(select entity_id from mc.player where name = 'P2')]));
select t.eq('visible is empty', (select count(*) from mc.visible)::int, 0);

select t.reset();
select mc.on_leave(2);
select t.is_true('leave: offline', (select conn_id is null and entity_id is null and last_seen is not null from mc.player where name = 'P2'));
select t.eq('leave: P1 gets the left message then the tab removal', t.out(1),
  mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.left', array[mc.tc_player('00000000-0000-0000-0000-000000003302', 'P2')], 'yellow')))
  || mc.pkt_player_info_remove(array['00000000-0000-0000-0000-000000003302'::uuid]));
select t.reset();
select mc.on_leave(999);
select t.eq('leave of an unknown connection is a no-op', (select count(*) from mc.play_out)::int, 0);

------------------------------------------------------------------------------------------------ rejoin keeps the persistent player
select t.reset();
select mc.on_join(5, '00000000-0000-0000-0000-000000003302', 'P2');
select t.eq('rejoin: same row, new session', (select count(*) from mc.player where uuid = '00000000-0000-0000-0000-000000003302')::int, 1);
select t.is_true('rejoin: position kept from last session', (select x > 100 from mc.player where name = 'P2'));
select mc.on_leave(5);
