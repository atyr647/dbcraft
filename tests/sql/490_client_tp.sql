-- this test pins the classic (simplified) player broadcast of sql/430-468; the vanilla tracker of sql/900-910 has its own test (900_vis.sql)
update mc.server_property set value = 'false' where key = 'dbcraft.vanilla-tracker';
-- Found with the REAL client (docs/REAL-CLIENT.md): "/tp Name" answered "No player was found".  Vanilla's /tp forms:
--   tp <destination>  |  tp <targets> <destination>  |  tp <x> <y> <z>  |  tp <targets> <x> <y> <z>
create or replace function t.send(conn int, pname text, body bytea) returns void language sql as $$
  insert into mc.play_in_work (conn_id, packet_id, body) values (conn, mc.sid(pname), body) $$;
create or replace function t.out(conn int) returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = conn $$;
create or replace function t.reset() returns void language sql as $$ truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick $$;

select t.reset(); truncate mc.visible; delete from mc.player; delete from mc.op; delete from mc.chat_log; delete from mc.ban; delete from mc.whitelist;
update mc.server_property set value = 'false' where key = 'white-list'; update mc.server_property set value = '20' where key = 'max-players';
update mc.server_property set value = 'survival' where key = 'gamemode';
update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');     -- as in the real-client runs: players further than 2 chunks apart do not see each other
select mc.on_join(1, '00000000-0000-0000-0000-000000004901', 'A');
select mc.on_join(2, '00000000-0000-0000-0000-000000004902', 'B');
insert into mc.op values ('00000000-0000-0000-0000-000000004901', 'A', 4, false);
update mc.player set x = 100.5, y = 70, z = -20.5, yaw = 90, pitch = 10 where name = 'B';
update mc.player set x = 0.5, y = -60, z = 0.5, yaw = 0, pitch = 0 where name = 'A';
update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int, vis_dirty = true,
                     sent_qx = mc.quant(x), sent_qy = mc.quant(y), sent_qz = mc.quant(z), sent_yaw = yaw, sent_pitch = pitch;
truncate mc.visible;
select mc.refresh_visibility();       -- A and B are 100+ blocks apart: they do not see each other
select t.reset();

------------------------------------------------------------------------------------------------ tp <destination>: the sender goes to the player
select t.send(1, 'chat_command', proto.string('tp B'));
select t.eq('/tp B: one command handled', (select commands from mc.apply_chat(1)), 1);
select t.eq('...the sender is at the destination', (select (x, y, z) from mc.player where name = 'A'), (100.5::float8, 70::float8, -20.5::float8));
select t.eq('...and has the destination''s rotation', (select (yaw, pitch) from mc.player where name = 'A'), (90::real, 10::real));
select t.is_true('...it must confirm the teleport', (select awaiting_teleport = teleport_id from mc.player where name = 'A'));
select t.eq('...the sender gets an absolute player_position (rotation of the destination), then "Teleported A to B"', t.out(1),
  mc.pkt_player_position((select teleport_id from mc.player where name = 'A'), 100.5, 70, -20.5, 0, 0, 0, 90, 10, 0)
  || mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('commands.teleport.success.entity.single',
       array[mc.tc_player('00000000-0000-0000-0000-000000004901', 'A'), mc.tc_player('00000000-0000-0000-0000-000000004902', 'B')]))));
select t.eq('...the destination is untouched', (select (x, y, z) from mc.player where name = 'B'), (100.5::float8, 70::float8, -20.5::float8));
select t.eq('...and gets nothing', t.out(2), '\x'::bytea);

------------------------------------------------------------------------------------------------ tp <targets> <destination>
update mc.player set x = -7.5, y = -60, z = 33.5, yaw = 180, pitch = 0 where name = 'A';
select t.reset();
select t.send(1, 'chat_command', proto.string('tp B A'));
select mc.apply_chat(2);
select t.eq('/tp B A: B moves to A', (select (x, y, z, yaw, pitch) from mc.player where name = 'B'), (-7.5::float8, -60::float8, 33.5::float8, 180::real, 0::real));
select t.eq('...B is told the position, the sender the feedback (B teleported to A)', t.out(2),
  mc.pkt_player_position((select teleport_id from mc.player where name = 'B'), -7.5, -60, 33.5, 0, 0, 0, 180, 0, 0));
select t.eq('...feedback goes to the sender', t.out(1),
  mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('commands.teleport.success.entity.single',
       array[mc.tc_player('00000000-0000-0000-0000-000000004902', 'B'), mc.tc_player('00000000-0000-0000-0000-000000004901', 'A')]))));
select t.eq('...the chunk is updated for the streaming step', (select (chunk_x, chunk_z) from mc.player where name = 'B'), (-1, 2));

------------------------------------------------------------------------------------------------ tp <x> <y> <z>: the sender is the target
select t.reset();
select t.send(1, 'chat_command', proto.string('tp 10 -60 10'));
select mc.apply_chat(3);
select t.eq('/tp 10 -60 10: the sender moves (integer coordinates are centred on the block)', (select (x, y, z) from mc.player where name = 'A'), (10.5::float8, -60::float8, 10.5::float8));
select t.is_true('...with the location feedback', position(convert_to('commands.teleport.success.location.single', 'UTF8') in t.out(1)) > 0);
select t.reset();
select t.send(1, 'chat_command', proto.string('tp ~ ~2 ~-3'));
select mc.apply_chat(4);
select t.eq('/tp ~ ~2 ~-3: relative to the sender', (select (x, y, z) from mc.player where name = 'A'), (10.5::float8, -58::float8, 7.5::float8));

------------------------------------------------------------------------------------------------ the old form still works; unknown names fail like before
select t.reset();
select t.send(1, 'chat_command', proto.string('tp B 1 2 3'));
select mc.apply_chat(5);
select t.eq('/tp B 1 2 3 still works', (select (x, y, z) from mc.player where name = 'B'), (1.5::float8, 2::float8, 3.5::float8));
select t.reset();
select t.send(1, 'chat_command', proto.string('tp Nobody'));
select mc.apply_chat(6);
select t.eq('/tp Nobody: "No entity was found" (what the real server says: /tp takes entities; sql/812 compares it byte for byte)', t.out(1), mc.pkt_system_chat(proto.nbt_root(mc.tc_failure(mc.tc_translate('argument.entity.notfound.entity')))));
select t.reset();
select t.send(1, 'chat_command', proto.string('tp A Nobody'));
select mc.apply_chat(7);
select t.eq('/tp A Nobody: the same', t.out(1), mc.pkt_system_chat(proto.nbt_root(mc.tc_failure(mc.tc_translate('argument.entity.notfound.entity')))));
select t.reset();
select t.send(2, 'chat_command', proto.string('tp A'));
select mc.apply_chat(8);
select t.is_true('a non-op still gets "unknown command" for the new form (two messages)', (select count(*) = 2 from mc.play_out where conn_id = 2));
select t.reset();

------------------------------------------------------------------------------------------------ the viewer that becomes visible in the SAME tick gets the entity at its real position
-- Found with two real clients: after "/tp" the add_entity carried the old position (70 blocks away, in a chunk the viewer had not loaded), and a real client keeps
-- such an entity hidden and ignores the teleport that follows.  A is at the origin, B and C are 200 blocks away and see each other; A (op) teleports B to A.
select mc.on_join(3, '00000000-0000-0000-0000-000000004903', 'C');
update mc.player set x = 0.5,   y = -60, z = 0.5,   yaw = 90, pitch = 5,  on_ground = true where name = 'A';
update mc.player set x = 200.5, y = -60, z = 200.5, yaw = 10, pitch = 0,  on_ground = true where name = 'B';
update mc.player set x = 202.5, y = -60, z = 200.5, yaw = 20, pitch = 0,  on_ground = true where name = 'C';
update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int, vis_dirty = true,
                     sent_qx = mc.quant(x), sent_qy = mc.quant(y), sent_qz = mc.quant(z), sent_yaw = yaw, sent_pitch = pitch;
truncate mc.visible;
select mc.refresh_visibility();
select t.is_true('baseline: B and C see each other, A sees nobody',
  (select count(*) from mc.visible v join mc.player a on a.entity_id = v.viewer_eid join mc.player b on b.entity_id = v.target_eid where a.name in ('B', 'C') and b.name in ('B', 'C')) = 2
  and not exists (select 1 from mc.visible v join mc.player a on a.entity_id = v.viewer_eid where a.name = 'A'));
select t.reset();
select t.send(1, 'chat_command', proto.string('tp B A'));
select mc.apply_chat(20);
select t.eq('B is at A''s position and rotation', (select (x, y, z, yaw, pitch) from mc.player where name = 'B'), (0.5::float8, -60::float8, 0.5::float8, 90::real, 5::real));
select t.eq('...and the shared "last told" position is current at once', (select (sent_qx, sent_qy, sent_qz) from mc.player where name = 'B'), (2048::bigint, -245760::bigint, 2048::bigint));
select t.eq('C, who saw B, is told right away: teleport_entity, then the head rotation',
  t.out(3), mc.pkt_teleport_entity((select entity_id from mc.player where name = 'B'), 0.5, -60, 0.5, 0, 0, 0, 90, 5, true)
         || mc.pkt_rotate_head((select entity_id from mc.player where name = 'B'), 90));
select t.reset();
select mc.refresh_visibility();
select t.is_true('A, who now sees B, gets add_entity at B''s REAL position (not the old 200.5, 200.5)',
  position(mc.pkt_add_player_entity((select entity_id from mc.player where name = 'B'), '00000000-0000-0000-0000-000000004902', 0.5, -60, 0.5, 90, 5, 90) in t.out(1)) > 0);
select t.is_true('...and no add_entity at the old position was sent',
  position(mc.pkt_add_player_entity((select entity_id from mc.player where name = 'B'), '00000000-0000-0000-0000-000000004902', 200.5, -60, 200.5, 10, 0, 10) in t.out(1)) = 0);
select t.is_true('C, who no longer sees B, is told to remove it',
  position(mc.pkt_remove_entities(array[(select entity_id from mc.player where name = 'B')]) in t.out(3)) > 0);
select t.reset();

------------------------------------------------------------------------------------------------ a SHORT teleport stays what it was: a relative move from the next movement step
-- (tests/sql/36 pins those bytes; the fix above only concerns jumps vanilla sends as teleport_entity)
update mc.player set x = 0.5, y = -60, z = 0.5 where name = 'B';
update mc.player set x = 2.5, y = -60, z = 0.5 where name = 'C';          -- C stands next to B: a real viewer
update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int, vis_dirty = true,
                     sent_qx = mc.quant(x), sent_qy = mc.quant(y), sent_qz = mc.quant(z), sent_yaw = yaw, sent_pitch = pitch where name in ('B', 'C');
truncate mc.visible;
select mc.refresh_visibility();
select t.is_true('C sees B before the short teleport', exists (select 1 from mc.visible v join mc.player c on c.entity_id = v.viewer_eid join mc.player b on b.entity_id = v.target_eid where c.name = 'C' and b.name = 'B'));
select t.reset();
select t.send(1, 'chat_command', proto.string('tp B ~ ~ ~3'));
select mc.apply_chat(21);
select t.eq('/tp B ~ ~ ~3: B moved 3 blocks', (select z from mc.player where name = 'B'), 3.5::float8);
select t.eq('...C (a viewer) is told nothing about B yet (the movement step sends the relative move)', t.out(3), '\x'::bytea);
select t.eq('...the shared position still waits for that step', (select sent_qz from mc.player where name = 'B'), 2048::bigint);
select t.reset();
