-- Survival core (sql/830-837): damage, fall, void, death, respawn, hunger, regeneration, eating, experience.
-- Expected bytes marked (vanilla) are packets recorded from the REAL vanilla 26.3 server by tests/e2e/survival_probe.py (same scenarios, replayed here through
-- the tick); the rules themselves are checked against numbers read from the bytecode (docs/SURVIVAL.md).
-- needs the datapack registries (damage types and their tags) and the recorded static packets (tools/load_datapack.py, tools/load_static_packets.py: the template of
-- tests/sql/prun.sh has them); without them the whole file is skipped with a notice
select (select count(*) from ref.dp_entry where registry = 'minecraft:damage_type') > 0 and (select count(*) from net.static_packet) >= 6 as have_data \gset
\if :have_data
create or replace function t.out(conn int) returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = conn $$;
create or replace function t.reset() returns void language sql as $$ truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick, mc.pending_ack $$;
create or replace function t.send(conn int, pname text, body bytea) returns void language sql as $$ insert into mc.play_in_work (conn_id, packet_id, body) values (conn, mc.sid(pname), body) $$;
-- the frames of a byte string as a list of packet names ('#id' for an unknown id), and the n-th frame's whole bytes
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
create or replace function t.frame(d bytea, n int) returns bytea language plpgsql as $$
declare o int := 0; l record; k int := 0;
begin
  while o < length(d) loop
    select * into l from proto.varint_read(d, o);
    k := k + 1; if k = n then return substring(d from o + 1 for l.nxt - o + l.val); end if;
    o := l.nxt + l.val;
  end loop;
  return null;
end $$;
-- one tick of the survival-relevant steps, as mc.tick_core runs them (the moves are applied by the caller before: positions are set with UPDATE)
create or replace function t.tick() returns bigint language plpgsql as $$
declare cur bigint; snap mc.surv_snap;
begin
  update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
  perform mc.survival_moves(cur, snap);
  perform mc.survival_input(cur);
  perform mc.refresh_visibility();
  perform mc.survival_entities(cur);
  return cur;
end $$;
-- a player move: positions before/after are given, the survival step sees the change like the tick does
create or replace function t.move(p_conn int, p_x float8, p_y float8, p_z float8, p_og boolean, p_sprint boolean default null) returns bigint language plpgsql as $$
declare cur bigint; snap mc.surv_snap;
begin
  update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
  if p_sprint is not null then update mc.player set sprinting = p_sprint where conn_id = p_conn; end if;
  snap := mc.survival_pre();
  update mc.player set x = p_x, y = p_y, z = p_z, on_ground = p_og, chunk_x = floor(p_x / 16)::int, chunk_z = floor(p_z / 16)::int where conn_id = p_conn;
  perform mc.survival_moves(cur, snap);
  perform mc.survival_input(cur);
  perform mc.refresh_visibility();
  perform mc.survival_entities(cur);
  return cur;
end $$;

update mc.server_property set value = 'false' where key = 'white-list'; update mc.server_property set value = 'survival' where key = 'gamemode';
update mc.server_property set value = 'normal' where key = 'difficulty'; update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
delete from mc.game_rule; truncate mc.tick_log;
update mc.game_state set game_time = 1000, day_time = 1000, spawn_x = 0.5, spawn_y = -60, spawn_z = 0.5, spawn_yaw = 0;
select t.reset(); truncate mc.visible; delete from mc.player;
select mc.generate_flat('minecraft:overworld', x, z) from generate_series(-2, 2) x, generate_series(-2, 2) z;

-- two players: S (the one the probe calls Surv, uuid and name as recorded) and O (observer)
select mc.on_join(1, '6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv');
select mc.on_join(2, '00000000-0000-0000-0000-000000830002', 'Obs');
update mc.player set x = 0.5, y = -60, z = 0.5, teleport_id = 1, awaiting_teleport = null where conn_id = 1;
update mc.player set x = 4.5, y = -60, z = 0.5, teleport_id = 1, awaiting_teleport = null where conn_id = 2;
select mc.refresh_visibility();
select t.reset();
select t.is_true('the join trigger starts a session with the current values counted as sent', (select sent_health = 20 and sent_food = 20 and sent_eh = 20 and join_tick = 1000 from mc.player where conn_id = 1));

------------------------------------------------------------------------------------------------ packet layouts (vanilla recordings)
select t.eq('set_health (vanilla: 16.8333, food 20, saturation 5)', encode(mc.pkt_set_health('16.833334'::real, 20, 5), 'hex'), '0a6a4186aaab1440a00000');
select t.eq('damage_event generic_kill, entity 166 (vanilla)', encode(mc.pkt_damage_event(166, 19), 'hex'), '0719a60113000000');
select t.eq('damage_event fall, entity 1 (vanilla)', encode(mc.pkt_damage_event(1, 10), 'hex'), '0619010a000000');
select t.eq('entity_event death, entity 3 (vanilla)', encode(mc.pkt_entity_event(3, 3), 'hex'), '0622000000030' || '3');
select t.eq('entity data: health 0.0 of entity 3 (vanilla)', encode(mc.pkt_data_health(3, 0), 'hex'), '096503090300000000ff');
select t.eq('entity data: using an item, entity 19 (vanilla)', encode(mc.pkt_data_using(19, true), 'hex'), '066513080001ff');
select t.eq('entity data: score 7, entity 22 (vanilla)', encode(mc.pkt_data_score(22, 7), 'hex'), '066516120107ff');
select t.eq('landing particles (vanilla: grass block, count 100)', encode(mc.pkt_particles_block(0.5, -60, 0.5, 9, 100), 'hex'),
  '3730010900003fe0000000000000c04e0000000000003fe00000000000000000000000000000000000003e19999a3e19999a3e19999a6400');
select t.eq('player_combat_kill: the /kill message of the real server (entity 3)',
  encode(mc.pkt_combat_kill(3, proto.nbt_root(mc.death_message('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv', 'generic_kill'))), 'hex'),
  'fa0145030a090004776974680a000000010a000b636c69636b5f6576656e74080006616374696f6e000f737567676573745f636f6d6d616e64080007636f6d6d616e64000b2f74656c6c2053757276200008000969'
  || '6e73657274696f6e000453757276080004746578740004537572760a000b686f7665725f6576656e740800046e616d65000453757276080006616374696f6e000b73686f775f656e74697479080002696400106d696e6563726166743a706c617965720b000475756964000000046e527204260b3f1585706f6e4efb389800000800097472616e736c617465001864656174682e61747461636b2e67656e657269634b696c6c00');
select t.eq('set_experience: level before total (vanilla: level 7, total 107, progress 0.4285714)', encode(mc.pkt_set_experience(0.42857128::real, 7, 107), 'hex'), '07693edb6db2076b');

------------------------------------------------------------------------------------------------ fall damage and regeneration (the recorded "fall" scenario)
-- Surv is teleported 12 blocks up and falls with the client's physics (gravity 0.08, drag 0.98; the step that reaches the floor is on the ground).  Vanilla answered with
-- level_particles (count 100), damage_event (fall), set_entity_data health 11.0, set_health 11.0 / 20 / 5.0, then +0.8333 health every 10 ticks with saturation 5, 4, 3, 3, 2, 1, 1, 1, 1 and a
-- last set_health when the saturation reached 0.
create temp table fall_log (tick bigint, s_out bytea, o_out bytea);
do $$
declare y float8 := -48; vy float8 := 0; ny float8; og boolean; cur bigint; n int := 0;
begin
  update mc.player set x = 0.5, y = -48, z = 0.5, on_ground = false, fall_tp = teleport_id where conn_id = 1;          -- the /tp up
  perform t.reset();
  loop
    vy := (vy - 0.08) * 0.98; ny := y + vy; og := false;
    if ny <= -60.0 then ny := -60.0; og := true; end if;
    cur := t.move(1, 0.5, ny, 0.5, og); y := ny;
    exit when og;
    n := n + 1; exit when n > 200;
  end loop;
  insert into fall_log values (cur, t.out(1), t.out(2)); perform t.reset();
  for i in 1..90 loop cur := t.move(1, 0.5, -60, 0.5, true); insert into fall_log values (cur, t.out(1), t.out(2)); perform t.reset(); end loop;
end $$;
select t.eq('fall: the landing tick tells the player: particles, damage_event, entity data, set_health',
  t.names((select s_out from fall_log order by tick limit 1)), array['level_particles', 'damage_event', 'set_entity_data', 'set_health']);
select t.eq('fall: the particles are the recorded ones (count 100)', encode(t.frame((select s_out from fall_log order by tick limit 1), 1), 'hex'),
  '3730010900003fe0000000000000c04e0000000000003fe00000000000000000000000000000000000003e19999a3e19999a3e19999a6400');
select t.eq('fall: damage_event (fall, entity of Surv)', encode(t.frame((select s_out from fall_log order by tick limit 1), 2), 'hex'),
  encode(mc.pkt_damage_event((select entity_id from mc.player where conn_id = 1), 10), 'hex'));
select t.eq('fall: health 11.0 in the entity data', encode(t.frame((select s_out from fall_log order by tick limit 1), 3), 'hex'),
  encode(mc.pkt_data_health((select entity_id from mc.player where conn_id = 1), 11), 'hex'));
select t.eq('fall: set_health 11.0 / 20 / 5.0 (vanilla 0a6a413000001440a00000)', encode(t.frame((select s_out from fall_log order by tick limit 1), 4), 'hex'), '0a6a413000001440a00000');
select t.eq('fall: the observer sees particles, damage_event and the entity data, not set_health',
  t.names((select o_out from fall_log order by tick limit 1)), array['level_particles', 'damage_event', 'set_entity_data']);
select t.eq('regeneration: the set_health packets after the landing, hex of (health, saturation) as vanilla sent them',
  (select array_agg(encode(substring(f from 3 for 4), 'hex') || '/' || encode(substring(f from 8 for 4), 'hex') order by tick)
     from (select tick, t.frame(s_out, n) as f from fall_log, generate_series(1, 2) n where tick > (select min(tick) from fall_log)) q where f is not null and get_byte(f, 1) = mc.pid('set_health')),
  array['413d5555/40a00000', '41480000/40800000', '41500000/40400000', '41580000/40400000', '415d5555/40000000', '41600000/3f800000', '4162aaab/3f800000', '41655556/3f800000', '41680001/3f800000', '41680001/00000000']);
select t.eq('regeneration: the set_health ticks after the landing (vanilla: the first heal 9 ticks after the damage, then every 10, the saturation flag one tick after the last)',
  (select array_agg(tick - (select min(tick) from fall_log) order by tick) from (select tick, t.frame(s_out, n) as f from fall_log, generate_series(1, 2) n where tick > (select min(tick) from fall_log)) q
    where f is not null and get_byte(f, 1) = mc.pid('set_health')), array[9, 19, 29, 39, 49, 59, 69, 79, 89, 90]::bigint[]);
select t.eq('regeneration: the entity data follows the set_health by one tick (vanilla: set_health at tick N, set_entity_data at N+1)',
  (select tick - 1 from fall_log where t.names(s_out) = array['set_entity_data'] order by tick limit 1), (select tick from fall_log where t.names(s_out) = array['set_health'] order by tick limit 1));
select t.eq('fall: Surv ended at 14.5 health', (select health from mc.player where conn_id = 1), '14.500001'::real);
select t.eq('fall: fall distance reset', (select fall_distance from mc.player where conn_id = 1), 0::float8);

------------------------------------------------------------------------------------------------ the void (recorded "void": 4 damage every 10 ticks, regeneration in between, death at the 6th hit)
update mc.player set health = 20, food = 20, saturation = 5, exhaustion = 0, food_timer = 0, hurt_tick = null, last_hurt = 0, sent_health = 20, sent_eh = 20, sent_sat_zero = false, cb_tick = null, cb_fall = 0
 where conn_id in (1, 2);
create temp table void_log (tick bigint, s_out bytea, o_out bytea);
do $$
declare cur bigint;
begin
  update mc.player set x = 0.5, y = -140, z = 0.5, on_ground = false where conn_id = 1;
  perform t.reset();
  for i in 1..120 loop
    update mc.game_state set game_time = game_time + 1 returning game_time into cur;
    perform mc.survival_input(cur); perform mc.refresh_visibility(); perform mc.survival_entities(cur);
    insert into void_log values (cur, t.out(1), t.out(2)); perform t.reset();
  end loop;
end $$;
select t.eq('void: the hits come 10 ticks apart (damage cooldown), the first one in the first tick',
  (select array_agg(tick - (select min(tick) from void_log) order by tick) from void_log where t.names(s_out) @> array['damage_event']), array[0, 10, 20, 30, 40, 50]::bigint[]);
select t.eq('void: the first tick: damage_event, set_health 16.0 (vanilla 0a6a418000001440a00000)', t.names((select s_out from void_log order by tick limit 1)), array['damage_event', 'set_health']);
select t.eq('void: set_health 16 / 20 / 5.0', encode(t.frame((select s_out from void_log order by tick limit 1), 2), 'hex'), '0a6a418000001440a00000');
select t.eq('void: every set_health of the run as vanilla sent it (health / saturation: hits, regeneration, saturation draining, death)',
  (select array_agg(encode(substring(f from 3 for 4), 'hex') || '/' || encode(substring(f from 8 for 4), 'hex') order by tick, n)
     from (select tick, n, t.frame(s_out, n) as f from void_log, generate_series(1, 6) n) q where f is not null and get_byte(f, 1) = mc.pid('set_health')),
  array['41800000/40a00000', '4186aaab/40a00000', '414d5556/40800000', '41580001/40800000', '41180001/40400000', '41200001/40400000', '40c00002/40400000', '40d00002/40400000', '40200004/40000000', '40355559/40000000', '00000000/3f800000']);
select t.eq('void: the entity data follows one tick later (damage came from the entity tick)', t.names((select s_out from void_log order by tick offset 1 limit 1)), array['set_entity_data']);
select t.eq('void: the observer sees damage_event first, then the entity data a tick later', array[t.names((select o_out from void_log order by tick limit 1)), t.names((select o_out from void_log order by tick offset 1 limit 1))],
  array[array['damage_event'], array['set_entity_data']]);
select t.is_true('void: dead after the 6th hit', (select dead and health = 0 from mc.player where conn_id = 1));
select t.eq('void: the death tick (as recorded): the pending entity data, damage_event, the death screen, the message, the death event, set_health 0',
  t.names((select s_out from void_log where t.names(s_out) @> array['player_combat_kill'])), array['set_entity_data', 'damage_event', 'player_combat_kill', 'system_chat', 'entity_event', 'set_health']);       -- (the first is the previous tick's regeneration reaching the entity data, as in the recording)
select t.eq('void: the death message (vanilla: death.attack.outOfWorld)', encode(t.frame((select s_out from void_log where t.names(s_out) @> array['player_combat_kill']), 4), 'hex'),
  encode(mc.pkt_system_chat(proto.nbt_root(mc.death_message('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv', 'out_of_world'))), 'hex'));
select t.eq('void: 19 ticks after the death the corpse is removed: entity_event 60, then remove_entities for the viewer',
  (select t.names(o_out) from void_log where t.names(o_out) @> array['remove_entities']), array['entity_event', 'remove_entities']);
select t.eq('void: that is 19 ticks after the death tick', (select tick from void_log where t.names(o_out) @> array['remove_entities']) - (select tick from void_log where t.names(s_out) @> array['player_combat_kill']), 19::bigint);
select t.is_true('void: the corpse is gone from mc.visible', not exists (select 1 from mc.visible where target_eid = (select entity_id from mc.player where conn_id = 1)));

------------------------------------------------------------------------------------------------ respawn (the recorded "kill" scenario), /kill
-- Surv is dead from the void run: respawn first so both players are alive again, then /kill as an operator
insert into mc.op (uuid, name, level) values ('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv', 4) on conflict do nothing;
select t.reset();
select t.send(1, 'client_command', '\x00');
update mc.game_state set game_time = game_time + 1;
select mc.survival_respawn((select game_time from mc.game_state));
select t.eq('respawn: what the real server sent, in its order (the first 21 packets, then the chunk batch)',
  (t.names(t.out(1)))[1:21], array['player_abilities', 'respawn', 'player_position', 'set_default_spawn_position', 'change_difficulty', 'set_experience', 'post_effects', 'initialize_border', 'set_time',
    'set_default_spawn_position', 'game_event', 'ticking_state', 'ticking_step', 'entity_event', 'commands', 'set_chunk_cache_center', 'container_set_content', 'set_entity_data', 'update_attributes',
    'set_health', 'set_experience']);
select t.is_true('respawn: then a chunk batch', (t.names(t.out(1)))[22] = 'chunk_batch_start' and (t.names(t.out(1)))[array_length(t.names(t.out(1)), 1)] = 'chunk_batch_finished');
select t.eq('respawn: abilities of a survival player (vanilla 0a41003d4ccccd3dcccccd)', encode(t.frame(t.out(1), 1), 'hex'), '0a41003d4ccccd3dcccccd');
select t.eq('respawn: player_position, teleport id 2 at the spawn (vanilla)', encode(t.frame(t.out(1), 3), 'hex'),
  '3e49023fe0000000000000c04e0000000000003fe0000000000000' || repeat('00', 36));
select t.eq('respawn: set_default_spawn_position (vanilla)', encode(t.frame(t.out(1), 4), 'hex'), '2563136d696e6563726166743a6f766572776f726c640000000000000fc40000000000000000');
select t.eq('respawn: change_difficulty normal (vanilla 030a0200)', encode(t.frame(t.out(1), 5), 'hex'), '030a0200');
select t.eq('respawn: set_experience, all zero (vanilla 0769000000000000)', encode(t.frame(t.out(1), 6), 'hex'), '0769000000000000');
select t.eq('respawn: post_effects (vanilla 025300)', encode(t.frame(t.out(1), 7), 'hex'), '025300');
select t.eq('respawn: game_event 13, ticking state, ticking step (vanilla)', array[encode(t.frame(t.out(1), 11), 'hex'), encode(t.frame(t.out(1), 12), 'hex'), encode(t.frame(t.out(1), 13), 'hex')],
  array['06270d00000000', '07820141a0000000', '03830100']);
select t.eq('respawn: entity_event 24 + op level 4 = 28 (vanilla ...1c)', encode(t.frame(t.out(1), 14), 'hex'), '06' || '22' || lpad(to_hex((select entity_id from mc.player where conn_id = 1)), 8, '0') || '1c');
select t.eq('respawn: the new state', (select row(dead, health, food, saturation, x, y, z, xp_level)::text from mc.player where conn_id = 1), '(f,20,20,5,0.5,-60,0.5,0)');
select t.is_true('respawn: the player is announced again to the observer by the same tick''s visibility pass', (select count(*) = 0 from mc.visible where target_eid = (select entity_id from mc.player where conn_id = 1)));
select mc.refresh_visibility();
select t.is_true('respawn: ... and the next pass re-adds both ways', (select count(*) = 2 from mc.visible));
select t.eq('respawn: the observer gets an add_entity for the respawned player', t.names(t.out(2)), array['add_entity']);

-- /kill (vanilla, recorded): the player gets damage_event, the death screen, the death message, entity_event 3, the command feedback, and in the same tick the entity data and set_health;
-- an observer gets damage_event, the death message, entity_event 3 and the entity data
select t.reset();
select mc.run_command(1, 'kill');
select t.eq('/kill: the death packets, then the feedback (vanilla order)', t.names(t.out(1)), array['damage_event', 'player_combat_kill', 'system_chat', 'entity_event', 'system_chat']);
select t.eq('/kill: the damage event is generic_kill (id 19)', encode(t.frame(t.out(1), 1), 'hex'), encode(mc.pkt_damage_event((select entity_id from mc.player where conn_id = 1), 19), 'hex'));
select t.eq('/kill: the feedback is commands.kill.success.single (vanilla)', encode(t.frame(t.out(1), 5), 'hex'),
  encode(mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('commands.kill.success.single', array[mc.tc_player('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv')]))), 'hex'));
select t.eq('/kill: the observer gets damage_event, the death message and entity_event 3', t.names(t.out(2)), array['damage_event', 'system_chat', 'entity_event']);
select mc.survival_entities((select game_time from mc.game_state));
select t.eq('/kill: then the entity data and set_health (vanilla: set_entity_data, set_health)', t.names(t.out(1)), array['damage_event', 'player_combat_kill', 'system_chat', 'entity_event', 'system_chat', 'set_entity_data', 'set_health']);
select t.eq('/kill: set_health 0 / 20 / 5.0', encode(t.frame(t.out(1), 7), 'hex'), '0a6a000000001440a00000');
select t.is_true('/kill: dead, health 0', (select dead and health = 0 from mc.player where conn_id = 1));
select t.reset();
select mc.run_command(1, 'kill');
select t.eq('a dead player cannot be killed again', t.names(t.out(1)), array['system_chat']);

-- a creative player dies from /kill (bypasses invulnerability) but takes no fall damage
select t.send(1, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state)); select mc.refresh_visibility(); select t.reset();
update mc.player set gamemode = 1 where conn_id = 2;
select t.eq('creative: damage is refused', mc.damage((select uuid from mc.player where conn_id = 2), 5), 0);
select mc.kill_players(array[(select uuid from mc.player where conn_id = 2)]);
select t.is_true('creative: /kill works', (select dead from mc.player where conn_id = 2));
update mc.player set gamemode = 0 where conn_id = 2;

------------------------------------------------------------------------------------------------ the damage rules (Player.hurtServer / LivingEntity.hurtServer)
select t.send(2, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state)); select mc.refresh_visibility(); select t.reset();
update mc.player set health = 20, hurt_tick = null, last_hurt = 0, exhaustion = 0 where conn_id in (1, 2);
-- damage cooldown: a second hit within 10 ticks counts only above the first one, and sends no event
update mc.game_state set game_time = 5000;
select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[4::real], 'generic', 5000);
select t.eq('hit 1: 4 damage', (select health from mc.player where conn_id = 1), 16::real);
select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[3::real], 'generic', 5003);
select t.eq('a weaker hit inside the cooldown does nothing', (select health from mc.player where conn_id = 1), 16::real);
select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[6::real], 'generic', 5004);
select t.eq('a stronger hit inside the cooldown counts the difference (6 - 4 = 2)', (select health from mc.player where conn_id = 1), 14::real);
select t.eq('only the full hit sent a damage event', (select count(*)::int from (select t.names(t.out(1)) n) q, unnest(q.n) u where u = 'damage_event'), 1);
select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[1::real], 'generic', 5010);
select t.eq('after 10 ticks a hit is full again', (select health from mc.player where conn_id = 1), 13::real);
-- difficulty scaling applies to damage types whose scaling is "always" (explosions), not to fall / void / starvation / generic
update mc.player set health = 20, hurt_tick = null, last_hurt = 0 where conn_id = 1;
update mc.server_property set value = 'peaceful' where key = 'difficulty'; select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[6::real], 'explosion', 6000);
select t.eq('explosion on peaceful: no damage', (select health from mc.player where conn_id = 1), 20::real);
update mc.server_property set value = 'easy' where key = 'difficulty'; select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[6::real], 'explosion', 6100);
select t.eq('explosion on easy: min(6 / 2 + 1, 6) = 4', (select health from mc.player where conn_id = 1), 16::real);
update mc.player set health = 20, hurt_tick = null where conn_id = 1;
update mc.server_property set value = 'hard' where key = 'difficulty'; select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[6::real], 'explosion', 6200);
select t.eq('explosion on hard: 6 * 3 / 2 = 9', (select health from mc.player where conn_id = 1), 11::real);
update mc.player set health = 20, hurt_tick = null where conn_id = 1;
select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[6::real], 'generic', 6300);
select t.eq('generic damage on hard is not scaled', (select health from mc.player where conn_id = 1), 14::real);
update mc.server_property set value = 'normal' where key = 'difficulty';
-- game rules: fall_damage off, keep_inventory, show_death_messages
update mc.player set health = 20, hurt_tick = null where conn_id = 1;
insert into mc.game_rule values ('minecraft:fall_damage', 'false');
select t.eq('fall damage off: the hit is refused', mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[5::real], 'fall', 6400), 0);
delete from mc.game_rule;
-- exhaustion: the damage type's own value (mob attack 0.1, fall 0) is added for survival players only
update mc.player set exhaustion = 0, hurt_tick = null where conn_id in (1, 2);
select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[1::real], 'in_fire', 6500);
select t.eq('in_fire adds its exhaustion 0.1', (select exhaustion from mc.player where conn_id = 1), 0.1::real);
select mc.hurt(array[(select entity_id from mc.player where conn_id = 1)], array[1::real], 'fall', 6600);
select t.eq('fall adds none', (select exhaustion from mc.player where conn_id = 1), 0.1::real);

------------------------------------------------------------------------------------------------ death: items, rules
select mc.set_slot((select uuid from mc.player where conn_id = 1), 36, 'minecraft:apple', 3);
select mc.set_slot((select uuid from mc.player where conn_id = 1), 9, 'minecraft:stone', 64);
update mc.player set health = 20, hurt_tick = null, dead = false where conn_id = 1;
-- entity simulation off (the default): nobody could simulate or show the items, so they are removed
select mc.kill_players(array[(select uuid from mc.player where conn_id = 1)]);
select t.eq('death with the entity simulation off: the inventory is cleared', (select count(*)::int from mc.inventory_slot where player = (select uuid from mc.player where conn_id = 1)), 0);
select t.eq('death with the entity simulation off: no item entities', (select count(*)::int from mc.entity where type = 'minecraft:item'), 0);
-- inline mode: one item entity per stack, at the player, with a 40 tick pickup delay
update mc.server_property set value = 'inline' where key = 'dbcraft.entity-mode';
select t.send(1, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state));
select mc.set_slot((select uuid from mc.player where conn_id = 1), 36, 'minecraft:apple', 3);
select mc.set_slot((select uuid from mc.player where conn_id = 1), 9, 'minecraft:stone', 64);
select mc.kill_players(array[(select uuid from mc.player where conn_id = 1)]);
select t.eq('death with the entity simulation inline: the stacks drop as item entities', (select array_agg(data ->> 'item' || ' ' || (data ->> 'count') order by data ->> 'item') from mc.entity where type = 'minecraft:item'), array['minecraft:apple 3', 'minecraft:stone 64']);
select t.is_true('the items start at the player (eye height - 0.3) and fly up', (select bool_and(abs(y - (-60 + 1.32)) < 1e-9 and vy = 0.2 and abs(x - 0.5) < 0.0001 + 0.5) from mc.entity where type = 'minecraft:item'));
select t.eq('the pickup delay is 40 ticks', (select max(pickup_at - born_tick) from mc.entity where type = 'minecraft:item')::int, 40);
delete from mc.entity; update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode';
-- keepInventory keeps the stacks and the experience
select t.send(1, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state));
insert into mc.game_rule values ('minecraft:keep_inventory', 'true');
select mc.set_slot((select uuid from mc.player where conn_id = 1), 36, 'minecraft:apple', 3); select mc.xp_give((select uuid from mc.player where conn_id = 1), 50);
select mc.kill_players(array[(select uuid from mc.player where conn_id = 1)]);
select t.eq('keepInventory: the inventory stays', (select count from mc.inventory_slot where player = (select uuid from mc.player where conn_id = 1) and slot = 36), 3::smallint);
select t.send(1, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state));
select t.eq('keepInventory: experience is kept across the respawn', (select xp_total from mc.player where conn_id = 1), 50);
delete from mc.game_rule;
-- showDeathMessages false: an empty message to the player, nobody else is told
select t.reset(); insert into mc.game_rule values ('minecraft:show_death_messages', 'false');
select mc.kill_players(array[(select uuid from mc.player where conn_id = 1)]);
select t.eq('showDeathMessages off: player_combat_kill with an empty component, no system_chat', t.names(t.out(1)), array['damage_event', 'player_combat_kill', 'entity_event']);
select t.eq('showDeathMessages off: the death screen text is empty', encode(t.frame(t.out(1), 2), 'hex'), encode(mc.pkt_combat_kill((select entity_id from mc.player where conn_id = 1), mc.nbt_root_text('')), 'hex'));
delete from mc.game_rule;
select t.send(1, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state)); select mc.refresh_visibility();
-- the death message of a long fall (fell from a high place) and a short one (hit the ground too hard)
select t.eq('a fall of more than 5 blocks: death.fell.accident.generic', encode(mc.death_message('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv', 'fall', 8), 'hex'),
  encode(mc.tc_translate('death.fell.accident.generic', array[mc.tc_player('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv')]), 'hex'));
select t.eq('a fall of 5 or less: death.attack.fall', encode(mc.death_message('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv', 'fall', 5), 'hex'),
  encode(mc.tc_translate('death.attack.fall', array[mc.tc_player('6e527204-260b-3f15-8570-6f6e4efb3898', 'Surv')]), 'hex'));

------------------------------------------------------------------------------------------------ hunger and regeneration (FoodData.tick)
create or replace function t.food(p_exh real, p_sat real, p_food int, p_health real, p_timer int) returns void language sql as $$
  update mc.player set exhaustion = p_exh, saturation = p_sat, food = p_food, health = p_health, food_timer = p_timer, sent_health = p_health, sent_food = p_food, sent_sat_zero = (p_sat = 0), sent_eh = p_health,
         hurt_tick = null, dead = false, cb_tick = null where conn_id = 1 $$;
create or replace function t.step(n int default 1) returns void language plpgsql as $$
declare cur bigint;
begin for i in 1..n loop update mc.game_state set game_time = game_time + 1 returning game_time into cur; perform mc.survival_entities(cur); end loop; end $$;
create or replace function t.p(col text) returns text language plpgsql as $$ declare r text; begin execute format('select %I::text from mc.player where conn_id = 1', col) into r; return r; end $$;
update mc.player set gamemode = 0, y = -60 where conn_id = 1;
select t.food(4.5, 5, 20, 20, 0); select t.step();
select t.eq('exhaustion above 4: -4 exhaustion, -1 saturation', array[t.p('exhaustion'), t.p('saturation'), t.p('food')], array['0.5', '4', '20']);
select t.food(4.5, 0, 20, 20, 0); select t.step();
select t.eq('no saturation: the food level drops', array[t.p('exhaustion'), t.p('saturation'), t.p('food')], array['0.5', '0', '19']);
select t.food(4.5, 0, 20, 20, 0); update mc.server_property set value = 'peaceful' where key = 'difficulty'; select t.step(); update mc.server_property set value = 'normal' where key = 'difficulty';
select t.eq('peaceful: the food level does not drop from exhaustion', t.p('food'), '20');
select t.food(0, 5, 20, 10, 0); select t.step(9);
select t.eq('saturated and hurt: nothing before the 10th tick', array[t.p('health'), t.p('food_timer')], array['10', '9']);
select t.step();
select t.eq('...then +min(sat, 6) / 6 health and that much exhaustion', array[t.p('health'), t.p('exhaustion'), t.p('food_timer')], array['10.833333', '5', '0']);
select t.food(0, 0, 20, 10, 0); select t.step(79);
select t.eq('food >= 18 without saturation: 80 ticks per half heart...', array[t.p('health'), t.p('food_timer')], array['10', '79']);
select t.step();
select t.eq('...+1 health, +6 exhaustion', array[t.p('health'), t.p('exhaustion')], array['11', '6']);
select t.food(0, 5, 17, 10, 0); select t.step(200);
select t.eq('food below 18: no natural regeneration', array[t.p('health'), t.p('food_timer')], array['10', '0']);
insert into mc.game_rule values ('minecraft:natural_health_regeneration', 'false'); select t.food(0, 5, 20, 10, 0); select t.step(30);
select t.eq('naturalRegeneration off: no healing', t.p('health'), '10'); delete from mc.game_rule;
-- starvation: food 0, every 80 ticks 1 damage: always above 10 health, on normal while above 1 health, on hard always, on easy only down to 10
select t.food(0, 0, 0, 20, 0); select t.step(80);
select t.eq('starving at 20 health: 1 damage after 80 ticks', t.p('health'), '19');
select t.food(0, 0, 0, 1, 0); select t.step(80);
select t.eq('normal: starvation stops at half a heart', t.p('health'), '1');
update mc.server_property set value = 'hard' where key = 'difficulty'; select t.food(0, 0, 0, 1, 0); select t.step(80);
select t.is_true('hard: starvation kills', (select dead from mc.player where conn_id = 1));
update mc.server_property set value = 'easy' where key = 'difficulty'; select t.send(1, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state));
select t.food(0, 0, 0, 10, 0); select t.step(80);
select t.eq('easy: starvation stops at 10 health', t.p('health'), '10');
update mc.server_property set value = 'normal' where key = 'difficulty';
-- peaceful regeneration (ServerPlayer.tickRegeneration): +1 health and +1 saturation every 20 ticks of the player's tick count, +1 food every 10
update mc.server_property set value = 'peaceful' where key = 'difficulty';
select t.food(0, 5, 10, 10, 0); update mc.player set join_tick = (select game_time from mc.game_state) where conn_id = 1; select t.step(20);
select t.eq('peaceful: after 20 ticks +1 health, +1 saturation, +2 food', array[t.p('health'), t.p('saturation'), t.p('food')], array['11', '6', '12']);
update mc.server_property set value = 'normal' where key = 'difficulty';

------------------------------------------------------------------------------------------------ exhaustion from moving (jump, sprint)
select t.food(0, 5, 20, 20, 0); update mc.player set x = 0.5, y = -60, z = 0.5, on_ground = true, sprinting = false, fall_tp = teleport_id where conn_id = 1;
select t.move(1, 0.5, -59.9, 0.5, false);
select t.eq('a jump costs 0.05', t.p('exhaustion'), '0.05');
select t.move(1, 0.5, -60, 0.5, true); select t.food(0, 5, 20, 20, 0);
select t.move(1, 0.5, -59.9, 0.5, false, true);
select t.eq('a sprinting jump costs 0.2', t.p('exhaustion'), '0.2');
select t.move(1, 0.5, -60, 0.5, true); select t.food(0, 5, 20, 20, 0);
select t.move(1, 1.5, -60, 0.5, true, true);
select t.eq('sprinting a metre on the ground costs 0.1F * 100 * 0.01F = 0.099999994 (float arithmetic)', t.p('exhaustion'), '0.099999994');
select t.move(1, 1.5, -60, 0.5, true, false); select t.food(0, 5, 20, 20, 0);
select t.move(1, 2.5, -60, 0.5, true);
select t.eq('walking costs nothing', t.p('exhaustion'), '0');
update mc.player set gamemode = 1 where conn_id = 1; select t.food(0, 5, 20, 20, 0);
select t.move(1, 2.5, -59.9, 0.5, false, true); select t.move(1, 3.5, -60, 0.5, true);
select t.eq('creative: no exhaustion', t.p('exhaustion'), '0');
update mc.player set gamemode = 0, sprinting = false where conn_id = 1;

------------------------------------------------------------------------------------------------ eating (the recorded "eat" scenario: food 19, saturation 0, an apple)
select t.send(1, 'client_command', '\x00'); select mc.survival_respawn((select game_time from mc.game_state)); select mc.refresh_visibility();
delete from mc.inventory_slot where player = (select uuid from mc.player where conn_id = 1);
select mc.set_slot((select uuid from mc.player where conn_id = 1), 36, 'minecraft:apple', 3);
update mc.player set held_slot = 0, inv_state = 7 where conn_id = 1;
select t.food(0, 0, 19, 20, 0); select t.reset();
create temp table eat_log (tick bigint, s_out bytea, o_out bytea, acks int);
do $$
declare cur bigint;
begin
  perform t.send(1, 'use_item', '\x00'::bytea || '\x01'::bytea || '\x0000000000000000'::bytea);
  for i in 1..40 loop
    update mc.game_state set game_time = game_time + 1 returning game_time into cur;
    perform mc.survival_input(cur); perform mc.refresh_visibility(); perform mc.survival_entities(cur);
    insert into eat_log values (cur, t.out(1), t.out(2), (select count(*)::int from mc.pending_ack)); perform t.reset();
  end loop;
end $$;
select t.eq('eating: the first tick sets the "using an item" flag (vanilla: set_entity_data 08 00 01), and the sequence is acknowledged',
  array[encode(t.frame((select s_out from eat_log order by tick limit 1), 1), 'hex'), (select acks::text from eat_log order by tick limit 1)],
  array['0665' || lpad(to_hex((select entity_id from mc.player where conn_id = 1)), 2, '0') || '080001ff', '1']);
select t.eq('eating: nothing more until the 32nd tick', (select count(*)::int from eat_log where tick between (select min(tick) + 1 from eat_log) and (select min(tick) + 31 from eat_log) and length(s_out) > 0), 0);
select t.eq('eating: tick 32: entity_event 9, then set_health 20 / 20 / 2.4 (vanilla 0a6a41a00000144019999a)', t.names((select s_out from eat_log order by tick offset 32 limit 1)), array['entity_event', 'set_health']);
select t.eq('eating: the entity event is 9 (finished using the item)', encode(t.frame((select s_out from eat_log order by tick offset 32 limit 1), 1), 'hex'),
  '0622' || lpad(to_hex((select entity_id from mc.player where conn_id = 1)), 8, '0') || '09');
select t.eq('eating: set_health', encode(t.frame((select s_out from eat_log order by tick offset 32 limit 1), 2), 'hex'), '0a6a41a00000144019999a');
select t.eq('eating: tick 33: the flag is cleared and the stack re-sent (vanilla: set_entity_data 08 00 00, container_set_slot)', t.names((select s_out from eat_log order by tick offset 33 limit 1)), array['set_entity_data', 'container_set_slot']);
select t.eq('eating: the flag reset', encode(t.frame((select s_out from eat_log order by tick offset 33 limit 1), 1), 'hex'), '0665' || lpad(to_hex((select entity_id from mc.player where conn_id = 1)), 2, '0') || '080000ff');
select t.eq('eating: the slot update (window 0, state 8, slot 36, 2 apples)', encode(t.frame((select s_out from eat_log order by tick offset 33 limit 1), 2), 'hex'),
  encode(mc.pkt_container_set_slot(8, 36, 'minecraft:apple', 2), 'hex'));
select t.eq('eating: the observer sees the flag and its reset, but not the finish event (recorded: the observer got 2 set_entity_data)', array[array_to_string(t.names((select o_out from eat_log order by tick limit 1)), ','), array_to_string(t.names((select o_out from eat_log order by tick offset 32 limit 1)), ','), array_to_string(t.names((select o_out from eat_log order by tick offset 33 limit 1)), ',')],
  array['set_entity_data', '', 'set_entity_data']);
select t.eq('eating: food 20, saturation 2.4, one apple less', array[t.p('food'), t.p('saturation'), (select count::text from mc.inventory_slot where player = (select uuid from mc.player where conn_id = 1) and slot = 36)], array['20', '2.4', '2']);
-- not hungry: nothing happens (apples cannot be eaten at 20 food), but golden apples can
select t.food(0, 5, 20, 20, 0); select t.send(1, 'use_item', '\x00'::bytea || '\x01'::bytea || '\x0000000000000000'::bytea); select mc.survival_input((select game_time from mc.game_state));
select t.is_true('a full player does not start eating an apple', (select use_slot is null from mc.player where conn_id = 1));
select mc.set_slot((select uuid from mc.player where conn_id = 1), 36, 'minecraft:golden_apple', 1);
select t.send(1, 'use_item', '\x00'::bytea || '\x02'::bytea || '\x0000000000000000'::bytea); select mc.survival_input((select game_time from mc.game_state));
select t.is_true('...but starts a golden apple (always edible)', (select use_slot = 36 from mc.player where conn_id = 1));
select t.send(1, 'player_action', '\x06'::bytea || proto.position(0, 0, 0) || '\x00'::bytea || '\x00'::bytea); select mc.survival_use((select game_time from mc.game_state), 'start');
select t.is_true('releasing the item cancels the use', (select use_slot is null from mc.player where conn_id = 1));
update mc.player set food = 10 where conn_id = 1; select mc.set_slot((select uuid from mc.player where conn_id = 1), 36, 'minecraft:mushroom_stew', 1);
select t.send(1, 'use_item', '\x00'::bytea || '\x03'::bytea || '\x0000000000000000'::bytea); select mc.survival_input((select game_time from mc.game_state));
select t.step(33);
select t.eq('a stew leaves a bowl in the slot', (select item from mc.inventory_slot where player = (select uuid from mc.player where conn_id = 1) and slot = 36), 'minecraft:bowl');
select t.eq('a stew: 6 food, 7.2 saturation', array[t.p('food'), t.p('saturation')], array['16', '12.2']);

------------------------------------------------------------------------------------------------ experience (the recorded "xp" scenario: /experience add 7 points, add 5 levels, set 0 levels, add 100 points, set 30 levels, add 1 level)
create or replace function t.xpstep(p_sql text) returns text language plpgsql as $$
declare cur bigint; nm text[]; k int;
begin
  perform t.reset(); execute p_sql;
  update mc.game_state set game_time = game_time + 1 returning game_time into cur;
  perform mc.survival_entities(cur);
  nm := t.names(t.out(1));
  select i into k from generate_subscripts(nm, 1) i where nm[i] = 'set_experience';
  return array_to_string(nm, ',') || ' ' || encode(t.frame(t.out(1), k), 'hex');
end $$;
create or replace function t.u() returns uuid language sql as $$ select uuid from mc.player where conn_id = 1 $$;
update mc.player set xp_level = 0, xp_progress = 0, xp_total = 0, xp_score = 0, sent_xp_total = 0, sent_score = 0 where conn_id = 1;
select t.eq('xp: add 7 points -> score entity data and set_experience 0 / level 1 / total 7 (vanilla 0769 00000000 01 07)', t.xpstep('select mc.xp_give(t.u(), 7)'), 'set_entity_data,set_experience 076900000000' || '0107');
select t.eq('xp: add 5 levels -> level 6, total unchanged (vanilla 0769 00000000 06 07), no score data', t.xpstep('select mc.xp_give_levels(t.u(), 5)'), 'set_experience 076900000000' || '0607');
select t.eq('xp: set 0 levels (vanilla 0769 00000000 00 07)', t.xpstep('select mc.xp_set_levels(t.u(), 0)'), 'set_experience 076900000000' || '0007');
select t.eq('xp: add 100 points -> level 7, progress 0.4285713, total 107 (vanilla 0769 3edb6db2 07 6b)', t.xpstep('select mc.xp_give(t.u(), 100)'), 'set_entity_data,set_experience 07693edb6db2' || '076b');
select t.eq('xp: set 30 levels (vanilla 0769 3edb6db2 1e 6b)', t.xpstep('select mc.xp_set_levels(t.u(), 30)'), 'set_experience 07693edb6db2' || '1e6b');
select t.eq('xp: add 1 level (vanilla 0769 3edb6db2 1f 6b)', t.xpstep('select mc.xp_give_levels(t.u(), 1)'), 'set_experience 07693edb6db2' || '1f6b');
select t.eq('xp: points needed for the next level: 7+2L below 15, 37+5(L-15) below 30, 112+9(L-30) from 30', array[mc.xp_needed(0), mc.xp_needed(14), mc.xp_needed(15), mc.xp_needed(29), mc.xp_needed(30), mc.xp_needed(31)], array[7, 35, 37, 107, 112, 121]);
select t.is_true('xp: no packet when nothing changed', t.xpstep('select 1') is null);

------------------------------------------------------------------------------------------------ the whole tick (mc.tick -> tick_core): sprinting from packets, a fall from position packets, the tick log
select t.food(0, 5, 20, 20, 0); update mc.player set x = 0.5, y = -60, z = 0.5, on_ground = true, sprinting = false, gamemode = 0, hurt_tick = null, fall_tp = teleport_id, awaiting_teleport = null where conn_id = 1;
select t.reset();
create or replace function t.pkt(conn int, pname text, body bytea) returns void language sql as $$ insert into mc.play_in (conn_id, packet_id, body) values (conn, mc.sid(pname), body) $$;
create or replace function t.posbody(x float8, y float8, z float8, og boolean) returns bytea language sql as $$ select proto.f64(x) || proto.f64(y) || proto.f64(z) || case when og then '\x01'::bytea else '\x00'::bytea end $$;
select t.pkt(1, 'player_command', proto.varint((select entity_id from mc.player where conn_id = 1)) || proto.varint(1) || proto.varint(0));
select t.pkt(1, 'client_tick_end', '\x'::bytea); select t.pkt(1, 'move_player_pos', t.posbody(1.0, -60, 0.5, true));
select mc.tick();
select t.is_true('tick: the sprint flag was read from player_command', (select sprinting from mc.player where conn_id = 1));
select t.eq('tick: sprinting half a metre costs 0.1 * 50 * 0.01', (select exhaustion from mc.player where conn_id = 1), '0.049999997'::real);
select t.pkt(1, 'player_command', proto.varint((select entity_id from mc.player where conn_id = 1)) || proto.varint(2) || proto.varint(0));
select t.pkt(1, 'client_tick_end', '\x'::bytea); select t.pkt(1, 'move_player_pos', t.posbody(1.5, -60, 0.5, true));
select mc.tick();
select t.is_true('tick: stop sprinting', not (select sprinting from mc.player where conn_id = 1));
select t.eq('tick: walking costs nothing', (select exhaustion from mc.player where conn_id = 1), '0.049999997'::real);
-- a fall of 5 blocks from position packets: floor(5 - 3) = 2 damage
update mc.player set y = -55, x = 1.5, on_ground = false, fall_distance = 0 where conn_id = 1;
do $$
declare y float8 := -55; vy float8 := 0; ny float8; og boolean;
begin
  loop
    vy := (vy - 0.08) * 0.98; ny := y + vy; og := false; if ny <= -60 then ny := -60; og := true; end if;
    perform t.pkt(1, 'client_tick_end', '\x'::bytea); perform t.pkt(1, 'move_player_pos', t.posbody(1.5, ny, 0.5, og));
    perform mc.tick(); y := ny; exit when og;
  end loop;
end $$;
select t.is_true('tick: a 5 block fall hurt (floor(5 - 3) = 2 or a little less from the discretisation)', (select health from mc.player where conn_id = 1) between 17.5 and 18.5);
select t.is_true('tick: the tick log has a survival column', (select count(*) > 0 from mc.tick_log where ms_survival is not null));
-- hay: a 20 block fall onto a hay bale takes a fifth (0.2): floor(17 * 0.2) = 3
select mc.set_block('minecraft:overworld', 1, -61, 0, 'minecraft:hay_block');
update mc.player set health = 20, hurt_tick = null, y = -40, x = 1.5, z = 0.5, on_ground = false, fall_distance = 0, fall_tp = teleport_id where conn_id = 1;
update mc.player set y = -40 where conn_id = 1;
do $$
declare y float8 := -40; vy float8 := 0; ny float8; og boolean; cur bigint; snap mc.surv_snap;
begin
  loop
    vy := (vy - 0.08) * 0.98; ny := y + vy; og := false; if ny <= -60 then ny := -60; og := true; end if;
    cur := t.move(1, 1.5, ny, 0.5, og); y := ny; exit when og;
  end loop;
end $$;
select t.eq('hay bale: the damage is 0.2 of the normal one', (select (20 - health)::int from mc.player where conn_id = 1), 3);
select mc.set_block('minecraft:overworld', 1, -61, 0, 'minecraft:grass_block');
select t.eq('a 4 block fall: floor(4 - 3 + 1e-6 ...) = 1 damage', (select floor(4.0 + 1e-6 - 3.0))::int, 1);

------------------------------------------------------------------------------------------------ mining and joining
-- breaking a block in survival costs 0.005 exhaustion (Block.playerDestroy)
select t.food(0, 5, 20, 20, 0); update mc.player set x = 0.5, y = -60, z = 0.5, gamemode = 0 where conn_id = 1;
select mc.set_block('minecraft:overworld', 1, -60, 0, 'minecraft:stone');
select t.reset(); truncate mc.block_event, mc.block_actor;
insert into mc.play_in_work (conn_id, packet_id, body) values (1, mc.sid('player_action'), proto.varint(3) || proto.position(1, -60, 0) || '\x01'::bytea || proto.varint(5));
select mc.apply_block_actions((select game_time from mc.game_state));
select t.eq('mining a block costs 0.005 exhaustion', (select exhaustion from mc.player where conn_id = 1), 0.005::real);
-- a player who left dead comes back alive at the world spawn with a fresh session, experience kept
update mc.player set conn_id = null, entity_id = null where conn_id = 2;
update mc.player set dead = true, health = 0, x = 50, z = 50, xp_level = 3, xp_total = 20, xp_progress = 0.5 where name = 'Obs';
update mc.player set conn_id = 2, entity_id = 99 where name = 'Obs';
select t.eq('join trigger: a player who left dead comes back alive at the spawn', (select row(dead, health, food, x, z)::text from mc.player where name = 'Obs'), '(f,20,20,0.5,0.5)');
select t.eq('join trigger: the experience survives the leave', (select row(xp_level, xp_total)::text from mc.player where name = 'Obs'), '(3,20)');
select t.eq('join trigger: what the burst carries counts as sent', (select row(sent_health, sent_xp_total, sent_eh)::text from mc.player where name = 'Obs'), '(20,20,20)');
do $$
declare j net.join_info := net.default_join_info(1, 0);
begin
  j.xp_progress := 0.5; j.xp_level := 3; j.xp_total := 20;
  perform t.eq('the join burst writes the experience as progress, level, total (found with /experience on the real server)',
    (select encode(body, 'hex') from net.play_entry_packets(1, j) where packet = 'minecraft:set_experience'), '3f0000000314');
end $$;
\else
\echo NOTICE: tests/sql/830_survival.sql skipped: the datapack and the static packets are not loaded (make test loads them)
\endif
