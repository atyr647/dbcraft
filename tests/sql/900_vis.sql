-- Player visibility (sql/900-910): entity data, equipment, attributes, swings, the pairing bundle, movement as other players see it, the locator bar, per-client view
-- distance, the chat rate limit.  Expected bytes marked (vanilla) are packets recorded from the REAL vanilla 26.3 server by tests/e2e/vis_probe.py (docs/PLAYER-VISIBILITY.md);
-- the rules are checked against what the 26.3 bytecode says (ServerEntity.sendChanges, ServerWaypointManager, ChunkMap.TrackedEntity.updatePlayer).
-- needs the generator reports (ref.registry) and the recorded static packets; the item components (tools/load_item_components.py) only for the armor attribute checks
select (select count(*) from ref.registry where registry = 'minecraft:attribute') > 0 and (select count(*) from net.static_packet) >= 6 as have_data \gset
\if :have_data
create or replace function t.out(conn int) returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = conn $$;
create or replace function t.reset() returns void language sql as $$ truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick, mc.pending_ack $$;
create or replace function t.send(conn int, pname text, body bytea) returns void language sql as $$ insert into mc.play_in_work (conn_id, packet_id, body) values (conn, mc.sid(pname), body) $$;
-- the names of the frames of a byte string
create or replace function t.names(d bytea) returns text[] language plpgsql as $$
declare o int := 0; l record; i record; r text[] := '{}'; nm text;
begin
  while o < length(d) loop
    select * into l from proto.varint_read(d, o); select * into i from proto.varint_read(d, l.nxt);
    select replace(name, 'minecraft:', '') into nm from ref.packet where state = 'play' and direction = 'clientbound' and protocol_id = i.val;
    r := r || coalesce(nm, '#' || i.val); o := l.nxt + l.val;
  end loop;
  return r;
end $$;
-- the body of the n-th frame
create or replace function t.body(d bytea, n int) returns bytea language plpgsql as $$
declare o int := 0; l record; i record; k int := 0;
begin
  while o < length(d) loop
    select * into l from proto.varint_read(d, o); select * into i from proto.varint_read(d, l.nxt);
    k := k + 1; if k = n then return substring(d from i.nxt + 1 for l.nxt + l.val - i.nxt); end if;
    o := l.nxt + l.val;
  end loop;
  return null;
end $$;
-- the body of the first waypoint frame
create or replace function t.wp(d bytea) returns bytea language plpgsql as $$
declare n text[] := t.names(d); i int;
begin
  for i in 1 .. coalesce(array_length(n, 1), 0) loop if n[i] = 'waypoint' then return t.body(d, i); end if; end loop;
  return null;
end $$;
-- the body of the first frame with the given name
create or replace function t.bn(d bytea, nm text) returns bytea language plpgsql as $$
declare n text[] := t.names(d); i int;
begin
  for i in 1 .. coalesce(array_length(n, 1), 0) loop if n[i] = nm then return t.body(d, i); end if; end loop;
  return null;
end $$;
-- one tick of the visibility steps as mc.tick_core runs them (moves are applied by the caller: positions are set with UPDATE, and last_move_tick says who moved)
create or replace function t.tick() returns bigint language plpgsql as $$
declare cur bigint;
begin
  update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
  perform mc.refresh_visibility();
  perform mc.vis_step(cur);
  return cur;
end $$;

update mc.server_property set value = 'false' where key = 'white-list'; update mc.server_property set value = 'survival' where key = 'gamemode';
update mc.server_property set value = 'normal' where key = 'difficulty'; update mc.server_property set value = '3' where key in ('view-distance', 'simulation-distance');
update mc.server_property set value = 'true' where key = 'dbcraft.vanilla-tracker';
delete from mc.game_rule; truncate mc.tick_log;
select t.eq('the tracker is on by default', mc.vis_on(), true);

------------------------------------------------------------------------------------------------ 1. entity data entries (vanilla bytes)
select t.eq('flags entry: crouching (0x02), recorded set_entity_data 02 00 00 02 ff', mc.pkt_entity_data(2, mc.ed_entries(2, 0, 0, 20, 1, 0, 0, 1)), mc.cb('set_entity_data', '\x0200' || '\x0002ff'::bytea));
select t.eq('pose entry: crouching = 5 (serializer 20), recorded 02 06 14 05 ff', mc.ed_entries(0, 5, 0, 20, 1, 0, 0, 2), '\x061405ff'::bytea);
select t.eq('sprinting flag 0x08 and invisible (spectator) 0x20 come from the state', mc.ed_flags(false, true, 0::smallint) | mc.ed_flags(true, false, 3::smallint), 8 | 32 | 2);
select t.eq('main arm left + skin layers 0x00: 0f 2a 00 10 00 00 ff (recorded 02 0f 2a 00 10 00 00 ff)', mc.ed_entries(0, 0, 0, 20, 0, 0, 0, 16 | 32), '\x0f2a00100000ff'::bytea);
select t.eq('health 20 and skin 0x41: recorded 09 03 41a00000 10 00 41 ff', mc.ed_entries(0, 0, 0, 20, 1, 65, 0, 8 | 32), '\x090341a00000100041ff'::bytea);

------------------------------------------------------------------------------------------------ 2. two players, a joiner, the pairing bundle
select mc.configure_dev_server('t', 'survival');
update mc.server_property set value = '3' where key in ('view-distance', 'simulation-distance'); select net.sync_settings();
insert into mc.player (uuid, name, gamemode, x, y, z, yaw, chunk_x, chunk_z, conn_id, entity_id, vis_dirty)
values ('00000000-0000-0000-0000-0000000000a1', 'Aa', 0, 0.5, -60, 0.5, 0, 0, 0, 101, 1, true), ('00000000-0000-0000-0000-0000000000b2', 'Bb', 0, 4.5, -60, 0.5, 0, 0, 0, 102, 2, true);
update mc.player set sent_health = health, sent_food = food, sent_sat_zero = false, sent_eh = health, sent_xp_total = 0, sent_score = 0, sent_using = false, join_tick = 0,
       sent_flags = 0, sent_pose = 0, sent_skin = 0, sent_arm = 1, attr_seen = mc.attr_std_seen(), trk_start = (select game_time from mc.game_state), vis_wake = null,
       trk_ground = true, trk_sync = -2, wp_state = 1, wp_bx = floor(x), wp_by = -60, wp_bz = 0, wp_cx = 0, wp_cz = 0, vis_x = x, vis_z = z, equip_dirty = false, attr_gm = 0, attr_spr = false,
       sent_equip = array['', '', '', '', '', ''], sent_held = 0, view_distance_req = 3, trk_first = false
 where conn_id in (101, 102);
update mc.player p set attr_sent = (select jsonb_object_agg(a.id::text, a.entry) from mc.attr_now(p.uuid, 0, 0, false, mc.attr_std_seen()) a) where conn_id in (101, 102);
insert into net.conn (conn_id, state, compression) values (101, 'play', -1), (102, 'play', -1) on conflict (conn_id) do update set state = 'play';
select t.reset();
select mc.refresh_visibility();
select t.eq('both see each other', (select count(*) from mc.visible), 2::bigint);
select t.eq('the viewer is sent a bundle: delimiter, add_entity, set_entity_data, update_attributes, delimiter', t.names(t.out(101)), array['bundle_delimiter', 'add_entity', 'set_entity_data', 'update_attributes', 'bundle_delimiter']);
select t.eq('set_entity_data of the bundle: health only (recorded: 02 09 03 41a00000 ff)', t.body(t.out(101), 3), '\x02090341a00000ff'::bytea);
select t.eq('update_attributes of the bundle: movement speed 0.1f, block range 4.5, entity range 3 (the three of vanilla; order is a hash set there)',
            t.body(t.out(101), 4), '\x0203084012000000000000000d4008000000000000001a3fb99999a000000000'::bytea);
select t.eq('add_entity: the exact position and the angle bytes the tracker last sent', t.body(t.out(101), 2), (select substring(mc.pkt_add_player_entity_b(2, '00000000-0000-0000-0000-0000000000b2', 4.5, -60, 0.5, 0, 0, 0) from 3)));

------------------------------------------------------------------------------------------------ 3. input: the shift key, a swing, client information, abilities
select t.reset();
select t.send(102, 'player_input', '\x20'::bytea);
select t.tick();
select t.eq('shift down: set_entity_data flags 0x02 to the player and to the viewer', t.names(t.out(101)), array['set_entity_data']);
select t.eq('   recorded body 02 00 00 02 ff', t.body(t.out(101), 1), '\x02000002ff'::bytea);
select t.eq('   the player gets it too', t.names(t.out(102)), array['set_entity_data']);
select t.reset();
select t.tick();
select t.eq('the pose follows one tick later (entity phase, then the next tracker): 02 06 14 05 ff', t.body(t.out(101), 1), '\x02061405ff'::bytea);
select t.reset();
select t.send(102, 'player_input', '\x20'::bytea), t.send(102, 'player_input', '\x00'::bytea);
select t.tick();
select t.eq('shift down and up in one tick: the flags are still sent (dirty entity data)', t.body(t.out(101), 1), '\x02000000ff'::bytea);
select t.reset();
select t.tick();
select t.eq('pose back to standing', t.body(t.out(101), 1), '\x02061400ff'::bytea);

select t.reset();
select t.send(102, 'punch', '\x'::bytea);
select t.tick();
select t.eq('punch: swing_animation to the viewer only (recorded 02 00 01 06)', t.body(t.out(101), 1), '\x02000106'::bytea);
select t.eq('   not to the swinger', t.names(t.out(102)), '{}'::text[]);
select t.reset();
select t.send(102, 'punch', '\x'::bytea);
select t.tick();
select t.eq('a second swing in the first half of the animation is ignored', t.names(t.out(101)), '{}'::text[]);

select t.reset();
select t.send(102, 'client_information', proto.string('en_us') || '\x03'::bytea || '\x00' || '\x01' || '\x7f' || '\x01' || '\x00' || '\x01' || '\x00');
select t.tick();
select t.eq('client information with the hat layer: player_info_update (hat) to everybody, then the entity data', t.names(t.out(101)), array['player_info_update', 'set_entity_data']);
select t.eq('   recorded: 80 01 uuid 01', t.body(t.out(101), 1), '\x8001'::bytea || proto.uuid('00000000-0000-0000-0000-0000000000b2') || '\x01'::bytea);
select t.eq('   skin layers 0x7f: 02 10 00 7f ff', t.body(t.out(101), 2), '\x0210007fff'::bytea);
select t.reset();
select t.send(102, 'client_information', proto.string('en_us') || '\x03'::bytea || '\x00' || '\x01' || '\x7f' || '\x01' || '\x00' || '\x01' || '\x00');
select t.tick();
select t.eq('the same information again: nothing', t.names(t.out(101)), '{}'::text[]);

------------------------------------------------------------------------------------------------ 4. equipment and attributes
select t.reset();
select mc.set_slot('00000000-0000-0000-0000-0000000000b2', 36, 'minecraft:iron_sword', 1);
select t.tick();
select t.eq('an iron sword in the main hand: set_equipment to the viewer (recorded 02 00 01 95 08 00 00)', t.body(t.out(101), 1), '\x020001'::bytea || proto.varint(mc.item_id('minecraft:iron_sword')) || '\x0000'::bytea);
select t.eq('   not to the wearer', t.names(t.out(102)), '{}'::text[]);
select t.reset();
select t.tick();
select (select count(*) from ref.item_attr) > 0 as have_items \gset
\if :have_items
select t.eq('   one tick later the sword changes the attack speed: update_attributes to both', t.names(t.out(101)), array['update_attributes']);
select t.eq('   recorded: attack_speed 4.0 with base_attack_speed -2.4',
            t.body(t.out(101), 1), '\x020105'::bytea || proto.f64(4.0) || '\x01'::bytea || proto.string('minecraft:base_attack_speed') || proto.f64(-2.4000000953674316) || '\x00'::bytea);
\endif
select t.reset();
select mc.set_slot('00000000-0000-0000-0000-0000000000b2', 36, null, 0), mc.set_slot('00000000-0000-0000-0000-0000000000b2', 36, 'minecraft:stone', 5);
select t.tick();
select t.eq('stone x 5: set_equipment 02 00 05 01 00 00 (recorded 02 00 05 01 00 00)', t.bn(t.out(101), 'set_equipment'), '\x02'::bytea || '\x00'::bytea || '\x05'::bytea || proto.varint(mc.item_id('minecraft:stone')) || '\x0000'::bytea);
select t.reset();
update mc.inventory_slot set count = 6 where player = '00000000-0000-0000-0000-0000000000b2' and slot = 36;
select t.tick();
select t.eq('a count-only change is sent too', t.names(t.out(101)), array['set_equipment']);
select t.reset();
update mc.player set held_slot = 1 where uuid = '00000000-0000-0000-0000-0000000000b2';
select t.tick();
select t.eq('another hotbar slot: the main hand is empty now (recorded 02 00 00)', t.body(t.out(101), 1), '\x020000'::bytea);

\if :have_items
select t.reset(); select t.tick();
select t.eq('one tick later the modifier is gone from the attack speed (recorded 02 01 05 4010000000000000 00)', t.body(t.out(101), 1), '\x020105'::bytea || proto.f64(4.0) || '\x00'::bytea);
\endif

-- sprinting: the modifier of the real server
select t.reset();
update mc.player set sprinting = true where uuid = '00000000-0000-0000-0000-0000000000b2';
select t.tick();
select t.eq('sprinting: set_entity_data flags 0x08 then update_attributes with the sprinting modifier', t.names(t.out(101)), array['set_entity_data', 'update_attributes']);
select t.eq('   recorded: 02 01 1a 3fb99999a0000000 01 "minecraft:sprinting" 0.30000001192092896 2',
            t.body(t.out(101), 2), '\x02011a3fb99999a000000001'::bytea || proto.string('minecraft:sprinting') || '\x3fd333334000000002'::bytea);
select t.reset();
update mc.player set sprinting = false where uuid = '00000000-0000-0000-0000-0000000000b2';
select t.tick();
select t.eq('stop sprinting: the flag and the attribute without the modifier (recorded 02 01 1a 3fb99999a0000000 00)', t.body(t.out(101), 2), '\x02011a3fb99999a000000000'::bytea);

------------------------------------------------------------------------------------------------ 5. movement as the viewers see it
insert into mc.game_rule (name, value) values ('minecraft:locator_bar', 'false') on conflict (name) do update set value = 'false';      -- (the locator bar has its own section)
select t.tick(); select t.reset();
update mc.player set held_slot = 0 where uuid = '00000000-0000-0000-0000-0000000000b2';
select t.tick(); select t.reset();
-- the body of the movement part runs on every second tick of the player's age (tick - trk_start); a walker moving 0.4316 blocks per two ticks sends one stepped packet
update mc.player set trk_start = (select game_time from mc.game_state) - 10, trk_sync = -2 + 0 where conn_id in (101, 102);
update mc.vtrk v set base_x = p.x, base_y = p.y, base_z = p.z from mc.player p where p.entity_id = v.entity_id;       -- both ages are even: bodies on every second tick from now on
select t.reset();
update mc.player set x = x + 0.2158, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102;                      -- tick of age 10 + 1: no body
select t.tick();
select t.eq('a tick that is not a movement-body tick sends no move packet', t.names(t.out(101)), '{}'::text[]);
update mc.player set x = x + 0.2158, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102;
select t.tick();
select t.eq('the body tick sends move_entity_pos with ticks = 2 and the delta (recorded 02 03 02 06e8 0000 0000)', t.body(t.out(101), 1), '\x02030206e800000000'::bytea);
select t.reset();
select t.tick(); select t.tick();
select t.eq('no movement, no packet on the next bodies', t.names(t.out(101)), '{}'::text[]);
-- the idle refresh every 60 ticks
select t.reset();
update mc.player set trk_start = (select game_time from mc.game_state) - 58 where conn_id = 102;          -- the next body has tickCount 60
select t.tick(); select t.tick();
select t.eq('tickCount % 60 = 0: a zero move is sent (recorded 02 03 02 00 00 00 00 00 00)', t.body(t.out(101), 1), '\x020302000000000000'::bytea);
-- the sync after 400 bodies without one (teleportDelay > 400): an idle player is pulled back to the exact position, even though nothing moved
select t.reset();
update mc.player set trk_start = (select game_time from mc.game_state) - 798, trk_sync = -2 where conn_id = 102;          -- the next body has tickCount 800: (800 + 2) / 2 = 401 > 400
select t.tick(); select t.tick();
select t.eq('400 bodies without a sync: entity_position_sync, with nothing moving', t.names(t.out(101)), array['entity_position_sync']);
select t.reset(); select t.tick(); select t.tick();
select t.eq('   and not again (trk_sync was reset)', t.names(t.out(101)), '{}'::text[]);
-- off the ground: a full position sync
select t.reset();
update mc.player set on_ground = false, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102;
select t.tick(); select t.tick();
select t.eq('the on-ground flag changed: entity_position_sync (stepped, 1 step of 2 ticks), not a move', t.names(t.out(101)), array['entity_position_sync']);
select t.eq('   ends with yaw 0, pitch 0, on ground 0', substring(t.body(t.out(101), 1) from length(t.body(t.out(101), 1)) - 8), '\x0000000000000000'::bytea || '\x00'::bytea);
-- a jump of more than 8 blocks
select t.reset();
update mc.player set on_ground = true, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102; select t.tick(); select t.tick(); select t.reset();
update mc.player set x = x + 9, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102;
select t.tick(); select t.tick();
select t.eq('a delta that does not fit in a short (9 blocks): a position sync, not a move', t.names(t.out(101)), array['entity_position_sync']);
select t.reset();
update mc.player set yaw = 90, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102;
select t.tick(); select t.tick();
select t.eq('only the rotation changed: move_entity_rot (on ground, yaw byte 0x40, pitch 0), then the head', t.names(t.out(101)), array['move_entity_rot', 'rotate_head']);
select t.eq('   move_entity_rot body', t.body(t.out(101), 1), '\x02014000'::bytea);

------------------------------------------------------------------------------------------------ 6. the locator bar
delete from mc.game_rule;
select t.tick(); select t.reset();
delete from mc.wp;
select t.eq('a pair at the same chunk: connected after the join of the second', (select count(*) from mc.wp), 0::bigint);
update mc.player set last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 101;
select t.tick();
select t.eq('a movement packet of the receiver makes its missing connections: a track of the block position', (select count(*) from mc.wp where kind = 1), 1::bigint);
select t.eq('   waypoint TRACK (op 0, uuid, minecraft:default, block position)', t.names(t.out(101)), array['waypoint']);
select t.reset();
update mc.player set x = x + 1.0, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102;
select t.tick();
select t.eq('the block position changed by one block: an UPDATE (op 2)', get_byte(t.wp(t.out(101)), 0), 2);
select t.reset();
update mc.player set x = x + 5, last_move_tick = (select game_time from mc.game_state) + 1 where conn_id = 102;
select t.tick();
select t.eq('a jump of more than one block breaks the connection: a TRACK again, no UNTRACK (recorded with /tp)', get_byte(t.wp(t.out(101)), 0), 0);
select t.reset();
update mc.player set pose = 5 where conn_id = 102;
select t.tick();
select t.eq('a crouching player stops transmitting: UNTRACK (op 1, type 0)', get_byte(t.wp(t.out(101)), 0), 1);
select t.reset();
update mc.player set pose = 0 where conn_id = 102;
select t.tick();
select t.eq('standing again: TRACK', get_byte(t.wp(t.out(101)), 0), 0);
select t.reset();
update mc.game_rule set value = 'false' where name = 'minecraft:locator_bar';
insert into mc.game_rule (name, value) values ('minecraft:locator_bar', 'false') on conflict (name) do update set value = 'false';
select t.tick();
select t.eq('gamerule locator_bar false: every connection is dropped', (select count(*) from mc.wp), 0::bigint);
delete from mc.game_rule;

------------------------------------------------------------------------------------------------ 7. visibility: the view distance of the viewer, spectators
select t.reset();
update mc.player set x = 4.5 + 40, chunk_x = 2, vis_dirty = true where conn_id = 102;
update mc.player set view_distance_req = 2 where conn_id = 101;       -- 32 blocks: the other one is 40 away
update mc.player set vis_dirty = true where conn_id = 101;
select t.tick();
select t.eq('a viewer with view distance 2 does not see a player 36 blocks away', (select count(*) from mc.visible where viewer_eid = 1), 0::bigint);
select t.eq('   a viewer with view distance 3 (48 blocks) sees the one 36 blocks away', (select count(*) from mc.visible where viewer_eid = 2), 1::bigint);
update mc.player set view_distance_req = 3, vis_dirty = true where conn_id = 101;
select t.reset(); select t.tick();
select t.eq('view distance 3: both see each other again', (select count(*) from mc.visible), 2::bigint);
update mc.player set x = 0.5 + 47.9, chunk_x = 3, vis_dirty = true where conn_id = 102; select t.tick();
select t.eq('47.9 blocks: still inside the circle of 48', (select count(*) from mc.visible where viewer_eid = 1), 1::bigint);
update mc.player set x = 0.5 + 48.1, chunk_x = 3, vis_dirty = true where conn_id = 102; select t.tick();
select t.eq('48.1 blocks: outside', (select count(*) from mc.visible where viewer_eid = 1), 0::bigint);
update mc.player set x = 4.5, chunk_x = 0, vis_dirty = true where conn_id = 102; select t.tick();
select t.reset();
update mc.player set gamemode = 3 where conn_id = 102;
select t.tick();
select t.eq('a spectator is still seen until a movement packet re-checks the pairs (vanilla re-evaluates in ChunkMap.move)', (select count(*) from mc.visible where viewer_eid = 1), 1::bigint);
update mc.player set last_move_tick = (select game_time from mc.game_state) + 1 where conn_id in (101, 102);
select t.reset(); select t.tick();
select t.eq('after the next movement packet the survival player does not see the spectator any more', (select count(*) from mc.visible where viewer_eid = 1), 0::bigint);
select t.eq('   the spectator still sees the survival player', (select count(*) from mc.visible where viewer_eid = 2), 1::bigint);
select t.eq('   the viewer was told to forget it', 'remove_entities' = any (t.names(t.out(101))), true);
update mc.player set gamemode = 0 where conn_id = 102;
update mc.player set last_move_tick = (select game_time from mc.game_state) + 1 where conn_id in (101, 102);
select t.reset(); select t.tick();
select t.eq('a player back in survival is paired again with a bundle', (t.names(t.out(101)))[1:3], array['bundle_delimiter', 'add_entity', 'set_entity_data']);

------------------------------------------------------------------------------------------------ 8. the chunk radius of a connection follows its view distance
select t.eq('a client that never said: view distance 2, a radius of 3 chunks', mc.view_dist(null) + 1, 3);
select t.eq('a client that asked for 3 while the server says 3: radius 4', mc.view_dist(3) + 1, 4);
select t.eq('a client that asked for 12 is capped by the server (3)', mc.view_dist(12), 3);
select t.eq('a client that asked for 1 gets the minimum 2', mc.view_dist(1), 2);

------------------------------------------------------------------------------------------------ 9. chat rate limit
update mc.player set conn_id = 101 where conn_id = 101;
select t.reset();
select t.tick();
insert into mc.chat_log (kind, sender, sender_name, message) select 'chat', '00000000-0000-0000-0000-0000000000b2', 'Bb', 'm' || g from generate_series(1, 9) g;
select t.tick();
select t.eq('nine messages in one tick: no kick', (select count(*) from mc.kick), 0::bigint);
insert into mc.chat_log (kind, sender, sender_name, message) values ('chat', '00000000-0000-0000-0000-0000000000b2', 'Bb', 'tenth');
select t.tick();
select t.eq('the tenth one tick later: 179 - 0 + 20 = 199, below 200 (the counter loses 1 a tick)', (select count(*) from mc.kick where conn_id = 102), 0::bigint);
insert into mc.chat_log (kind, sender, sender_name, message) values ('chat', '00000000-0000-0000-0000-0000000000b2', 'Bb', 'eleventh');
select t.tick();
select t.eq('the eleventh reaches 200: disconnect.spam', (select count(*) from mc.kick where conn_id = 102), 1::bigint);
select t.eq('   with the translation key', (select encode(reason_nbt, 'escape') ~ 'disconnect.spam' from mc.kick where conn_id = 102), true);
select t.reset();
insert into mc.op (uuid, name, level) values ('00000000-0000-0000-0000-0000000000a1', 'Aa', 4) on conflict do nothing;
insert into mc.chat_log (kind, sender, sender_name, message) select 'command', '00000000-0000-0000-0000-0000000000a1', 'Aa', 'list' from generate_series(1, 30) g;
select t.tick();
select t.eq('an operator is not kicked for spam', (select count(*) from mc.kick where conn_id = 101), 0::bigint);

------------------------------------------------------------------------------------------------ 10. the entry burst of a first-time and of a returning player
update mc.player set fresh_join = false, skin_parts = 0, main_hand = 1 where conn_id = 102;     -- a client that has not sent its client_information yet
select t.eq('returning: the burst carries the recipes (170 bytes recorded) at ord 90 and update_attributes at ord 240',
            (select array_agg(ord order by ord) from mc.join_static_packets(2) where packet in ('minecraft:recipe_book_add', 'minecraft:update_attributes', 'minecraft:set_entity_data')), array[90, 230, 240]);
update mc.player set fresh_join = true where conn_id = 102;
select t.eq('first-time: an empty recipe_book_add at ord 90, the recipes after set_entity_data (ord 235), no update_attributes in the burst',
            (select array_agg(ord order by ord) from mc.join_static_packets(2) where packet in ('minecraft:recipe_book_add', 'minecraft:update_attributes', 'minecraft:set_entity_data')), array[90, 230, 235]);
select t.eq('   the empty recipe_book_add is 00 01', (select body from mc.join_static_packets(2) where ord = 90 and packet = 'minecraft:recipe_book_add'), '\x0001'::bytea);
select t.eq('   its own entity data: health only (recorded 02 09 03 41a00000 ff)', (select body from mc.join_static_packets(2) where ord = 230), '\x02090341a00000ff'::bytea);
update mc.player set fresh_join = false where conn_id = 102;
select t.eq('a player with all skin layers and the left hand: the entity data of the burst says so (recorded 09 03 .. 0f 2a 00 10 00 7f)',
            (select substring(body from 2) from (select ('x' || '') as dummy) q, lateral (select proto.varint(2) || mc.ed_entries(0, 0, 0, 20, 0, 127, 0, 8 | 16 | 32) as body) b), '\x090341a000000f2a0010007fff'::bytea);

------------------------------------------------------------------------------------------------ 11. the work finder loses nothing
-- mc.vis_find (sql/905) decides which players the movement step looks at.  The same random 90-tick script (moves, turns, jumps, teleports, a crouching player, a game mode change, a 60-tick
-- refresh, a join) is run twice from the same state: once as it is, once with every player looked at every tick (dbcraft.vis_scan_all).  The bytes every connection receives must be the same.
create or replace function t.finder_run(p_all boolean) returns text language plpgsql as $$
declare i int; k int; gt bigint; digest text := ''; r record; n int;
begin
  perform set_config('session_replication_role', 'replica', false);
  delete from mc.player; delete from mc.vtrk; delete from mc.visible; delete from mc.wp; delete from net.conn where conn_id between 201 and 206;
  insert into mc.player select * from t.snap_player;
  insert into mc.vtrk select * from t.snap_vtrk;
  insert into mc.visible select * from t.snap_visible;
  update mc.game_state set game_time = (select game_time from t.snap_game);
  perform set_config('session_replication_role', 'origin', false);
  perform set_config('dbcraft.vis_scan_all', case when p_all then 'on' else 'off' end, false);
  perform t.reset();
  perform setseed(0.4242);
  for i in 1 .. 90 loop
    gt := (select game_time from mc.game_state) + 1;
    for k in 1 .. 5 loop
      n := floor(random() * 100);
      if n < 40 then
        update mc.player set x = x + (random() - 0.5) * 0.9, z = z + (random() - 0.5) * 0.9, yaw_prev = yaw, last_move_tick = gt where conn_id = 200 + k;
      elsif n < 55 then
        update mc.player set yaw_prev = yaw, yaw = (yaw + 7 + random() * 40)::real, last_move_tick = gt where conn_id = 200 + k;
      elsif n < 60 then
        update mc.player set on_ground = not on_ground, last_move_tick = gt where conn_id = 200 + k;
      elsif n < 62 then
        update mc.player set x = x + 12, chunk_x = floor((x + 12) / 16)::int, vis_dirty = true where conn_id = 200 + k;
        perform mc.sync_entity_position((select uuid from mc.player where conn_id = 200 + k));
      elsif n < 65 then
        update mc.player set shift = not shift where conn_id = 200 + k;
      end if;
    end loop;
    if i = 40 then update mc.player set gamemode = 3 where conn_id = 203; end if;
    if i = 70 then update mc.player set gamemode = 0 where conn_id = 203; end if;
    perform t.tick();
    for r in select conn_id, md5(string_agg(data, '\x'::bytea order by seq)) as h from mc.play_out group by conn_id order by conn_id loop
      digest := digest || i || ':' || r.conn_id || '=' || r.h || ';';
    end loop;
    perform t.reset();
  end loop;
  digest := digest || (select string_agg(entity_id || ':' || base_x || ',' || base_z || ',' || sent_yb || ',' || sent_hb, ';' order by entity_id) from mc.vtrk);
  return md5(digest);
end $$;

select t.reset();
set session_replication_role = replica;
delete from mc.player; delete from mc.vtrk; delete from mc.visible; delete from mc.wp; delete from net.conn where conn_id between 201 and 206;
set session_replication_role = origin;
insert into mc.player (uuid, name, gamemode, x, y, z, yaw, chunk_x, chunk_z, conn_id, entity_id, vis_dirty)
select ('00000000-0000-0000-0000-0000000000' || lpad(to_hex(10 + k), 2, '0'))::uuid, 'F' || k, 0, 2.5 * k, -60, 0.5 + k, 0, 0, 0, 200 + k, 20 + k, true from generate_series(1, 5) k;
insert into net.conn (conn_id, state, compression) select 200 + k, 'play', -1 from generate_series(1, 5) k on conflict (conn_id) do update set state = 'play';
update mc.player p set sent_health = health, sent_food = food, sent_sat_zero = false, sent_eh = health, sent_xp_total = 0, sent_score = 0, sent_using = false, join_tick = 0,
       sent_flags = 0, sent_pose = 0, sent_skin = 0, sent_arm = 1, attr_seen = mc.attr_std_seen(), trk_start = (select game_time from mc.game_state) - 3 - (conn_id % 2), vis_wake = null, trk_first = false,
       trk_ground = true, trk_sync = -2, wp_state = 1, vis_x = x, vis_z = z, equip_dirty = false, attr_gm = 0, attr_spr = false, view_distance_req = 3,
       sent_equip = array['', '', '', '', '', ''], sent_held = 0, wp_bx = floor(x)::int, wp_by = -60, wp_bz = floor(z)::int, wp_cx = 0, wp_cz = 0
 where conn_id between 201 and 205;
update mc.player p set attr_sent = (select jsonb_object_agg(a.id::text, a.entry) from mc.attr_now(p.uuid, 0, 0, false, mc.attr_std_seen()) a) where conn_id between 201 and 205;
select mc.refresh_visibility();
select t.reset();
create table t.snap_player as select * from mc.player;
create table t.snap_vtrk as select * from mc.vtrk;
create table t.snap_visible as select * from mc.visible;
create table t.snap_game as select game_time from mc.game_state;
select t.eq('the five players see each other', (select count(*) from mc.visible), 20::bigint);
create table t.fa as select t.finder_run(false) as h;
create table t.fb as select t.finder_run(true) as h;
select t.eq('90 ticks of random movement: the finder and a look at everybody send the same bytes and leave the same tracker state', (select h from t.fa), (select h from t.fb));
select t.is_true('...and the run was not empty (a digest of more than the empty script)', (select h <> md5('') from t.fa));
reset session_replication_role;
set dbcraft.vis_scan_all = 'off';

select 'mc.vis_*: all checks passed' as result;
\else
select 'SKIPPED: tests/sql/900_vis.sql needs the generator reports and the recorded static packets' as result;
\endif
