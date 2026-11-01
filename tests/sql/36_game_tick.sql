-- chat intake, creative slots, held slot, keep-alive, time, command permissions, tick log
create or replace function t.send(conn int, pname text, body bytea) returns void language sql as $$
  insert into mc.play_in_work (conn_id, packet_id, body) values (conn, mc.sid(pname), body) $$;
create or replace function t.out(conn int) returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = conn $$;
create or replace function t.reset() returns void language sql as $$ truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick $$;

select t.reset(); truncate mc.visible; delete from mc.player; delete from mc.op; delete from mc.chat_log; delete from mc.ban; delete from mc.whitelist;
update mc.server_property set value = 'false' where key = 'white-list'; update mc.server_property set value = '20' where key = 'max-players';
update mc.server_property set value = 'survival' where key = 'gamemode';
update mc.game_state set game_time = 0, day_time = 0, raining = false, thundering = false;
select mc.on_join(1, '00000000-0000-0000-0000-000000003601', 'A');
select mc.on_join(2, '00000000-0000-0000-0000-000000003602', 'B');
select mc.refresh_visibility();
select t.reset();

------------------------------------------------------------------------------------------------ chat
select t.send(1, 'chat', proto.string('hi all') || proto.i64(1700000000000) || proto.i64(42) || '\x00'::bytea || proto.varint(0) || '\x000000'::bytea || '\x00'::bytea);
select t.eq('chat: one message handled', (select messages from mc.apply_chat(1)), 1);
select t.eq('chat: logged', (select count(*) from mc.chat_log where kind = 'chat' and message = 'hi all')::int, 1);
select t.eq('chat: both players get an unsigned player_chat with per-recipient index 0, sender index 0', t.out(2),
  mc.pkt_player_chat(0, '00000000-0000-0000-0000-000000003601', 0, 'hi all', 1700000000000, 42, 0, mc.tc_player('00000000-0000-0000-0000-000000003601', 'A')));
select t.reset();
select t.send(1, 'chat', proto.string('second') || proto.i64(1) || proto.i64(2) || '\x00'::bytea || proto.varint(0) || '\x000000'::bytea || '\x00'::bytea);
select mc.apply_chat(2);
select t.eq('chat: the second message has sender index 1 and recipient index 1',
  t.out(2), mc.pkt_player_chat(1, '00000000-0000-0000-0000-000000003601', 1, 'second', 1, 2, 0, mc.tc_player('00000000-0000-0000-0000-000000003601', 'A')));
select t.reset();
select t.send(1, 'chat', proto.string(E'bad\x07char') || proto.i64(1) || proto.i64(2) || '\x00'::bytea || proto.varint(0) || '\x000000'::bytea || '\x00'::bytea);
select mc.apply_chat(3);
select t.eq('illegal character: kicked with the vanilla key', (select reason_nbt from mc.kick where conn_id = 1), proto.nbt_root(mc.disconnect_nbt('multiplayer.disconnect.illegal_characters')));
select t.reset();
select t.send(1, 'chat', '\xff'::bytea);          -- truncated garbage must not abort the tick
select t.eq('garbage chat packet does not raise', (select messages from mc.apply_chat(4)), 0);
select t.reset();
select t.send(1, 'chat', proto.string(repeat('x', 257)) || proto.i64(1) || proto.i64(2) || '\x00'::bytea || proto.varint(0) || '\x000000'::bytea || '\x00'::bytea);
select mc.apply_chat(5);
select t.is_true('257 characters: kicked', exists (select 1 from mc.kick where conn_id = 1));
select t.reset();

------------------------------------------------------------------------------------------------ command permissions
select t.send(1, 'chat_command', proto.string('gamemode creative'));
select t.eq('a non-op using /gamemode is told "unknown command" (two messages, as vanilla)', (select commands from mc.apply_chat(6)), 1);
select t.eq('...and the player is unchanged', (select gamemode from mc.player where name = 'A'), 0::smallint);
select t.eq('...the answer is the two-message unknown command feedback', (select count(*) from mc.play_out where conn_id = 1)::int, 2);
insert into mc.op values ('00000000-0000-0000-0000-000000003601', 'A', 4, false);
select t.reset();
select t.send(1, 'chat_command', proto.string('gamemode creative'));
select mc.apply_chat(7);
select t.eq('an op can: game mode changed', (select gamemode from mc.player where name = 'A'), 1::smallint);
select t.reset();
select t.send(1, 'chat_command', proto.string('time set noon'));
select mc.apply_chat(8);
select t.eq('/time set noon moves the clock to the next noon', (select day_time from mc.game_state), 6000::bigint);
select t.reset();
select t.send(1, 'chat_command', proto.string('tp B ~ ~ ~5'));
select mc.apply_chat(9);
select t.eq('/tp with a relative coordinate', (select z from mc.player where name = 'B'), 5.5::float8);
select t.is_true('...and B must confirm the teleport', (select awaiting_teleport is not null from mc.player where name = 'B'));
select t.reset();
select t.send(1, 'chat_command', proto.string('give B minecraft:diamond 70'));
select mc.apply_chat(10);
select t.eq('/give 70 diamonds fills one stack of 64 and then 6 in the next slot', (select string_agg(slot || ':' || count, ',' order by slot) from mc.inventory_slot where player = '00000000-0000-0000-0000-000000003602'), '36:64,37:6');
select t.reset();
select t.send(1, 'chat_command', proto.string('give B minecraft:not_an_item'));
select mc.apply_chat(11);
select t.is_true('/give of an unknown item changes nothing', (select count(*) = 2 from mc.inventory_slot where player = '00000000-0000-0000-0000-000000003602'));
select t.reset();
select t.send(1, 'chat_command', proto.string('op B'));
select mc.apply_chat(12);
select t.eq('/op B: B is an op at the configured level', (select level from mc.op where name = 'B'), 4);
select t.send(1, 'chat_command', proto.string('deop B'));
select mc.apply_chat(13);
select t.is_true('/deop B', not exists (select 1 from mc.op where name = 'B'));
select t.send(1, 'chat_command', proto.string('ban B griefing'));
select mc.apply_chat(14);
select t.eq('/ban records the reason', (select reason from mc.ban where kind = 'player'), 'griefing');
select t.is_true('...and kicks B', exists (select 1 from mc.kick where conn_id = 2));
select t.send(1, 'chat_command', proto.string('pardon B'));
select mc.apply_chat(15);
select t.eq('/pardon', (select count(*) from mc.ban)::int, 0);
select t.reset();
select t.send(1, 'chat_command', proto.string('say  hello   there '));
select mc.apply_chat(16);
select t.eq('/say: logged', (select message from mc.chat_log where kind = 'say'), 'hello   there');

------------------------------------------------------------------------------------------------ creative slot, held slot
select t.reset(); delete from mc.inventory_slot;
update mc.player set gamemode = 1 where name = 'B';
-- ItemStack: VarInt count, VarInt item id, VarInt added components, VarInt removed components
select t.send(2, 'set_creative_mode_slot', proto.i16(36) || proto.varint(5) || proto.varint(mc.item_id('minecraft:stone')) || proto.varint(0) || proto.varint(0));
select mc.apply_misc_input(20);
select t.eq('creative slot set', (select (item, count)::text from mc.inventory_slot where player = '00000000-0000-0000-0000-000000003602' and slot = 36), '(minecraft:stone,5)');
select t.send(2, 'set_creative_mode_slot', proto.i16(36) || proto.varint(0));
select mc.apply_misc_input(21);
select t.is_true('count 0 clears the slot', not exists (select 1 from mc.inventory_slot where player = '00000000-0000-0000-0000-000000003602'));
update mc.player set gamemode = 0 where name = 'B';
select t.send(2, 'set_creative_mode_slot', proto.i16(36) || proto.varint(5) || proto.varint(mc.item_id('minecraft:stone')) || proto.varint(0) || proto.varint(0));
select mc.apply_misc_input(22);
select t.is_true('a survival player cannot set slots', not exists (select 1 from mc.inventory_slot where player = '00000000-0000-0000-0000-000000003602'));
update mc.player set gamemode = 1 where name = 'B';
select t.send(2, 'set_creative_mode_slot', proto.i16(99) || proto.varint(5) || proto.varint(mc.item_id('minecraft:stone')) || proto.varint(0) || proto.varint(0));
select t.send(2, 'set_creative_mode_slot', '\x00'::bytea);
select mc.apply_misc_input(23);
select t.is_true('out of range slot and a truncated packet are ignored', not exists (select 1 from mc.inventory_slot where player = '00000000-0000-0000-0000-000000003602'));
select t.send(2, 'set_creative_mode_slot', proto.i16(40) || proto.varint(1) || proto.varint(mc.item_id('minecraft:stone')) || proto.varint(1) || proto.varint(0) || '\x0a'::bytea);
select mc.apply_misc_input(24);
select t.is_true('a stack with data components keeps its raw bytes instead of losing them', (select components ? 'raw_hex' from mc.inventory_slot where slot = 40));
select t.send(2, 'set_carried_item', proto.i16(3)); select mc.apply_misc_input(25);
select t.eq('held slot', (select held_slot from mc.player where name = 'B'), 3::smallint);
select t.send(2, 'set_carried_item', proto.i16(9)); select mc.apply_misc_input(26);
select t.eq('held slot 9 is out of range and ignored', (select held_slot from mc.player where name = 'B'), 3::smallint);

------------------------------------------------------------------------------------------------ keep-alive
select t.reset(); update mc.player set keepalive_id = null, keepalive_sent_tick = null;
select t.eq('keep-alive: both players get one at tick 300', (select sent from mc.keepalive_due(300)), 2);
select t.eq('keep-alive frame', t.out(1), mc.pkt_keep_alive(300));
select t.eq('not again before an answer', (select sent from mc.keepalive_due(301)), 0);
select t.send(1, 'keep_alive', proto.i64(300)); select mc.apply_misc_input(310);
select t.eq('answered: latency is (3*0 + 10 ticks * 50 ms) / 4', (select latency_ms from mc.player where name = 'A'), 125);
select t.is_true('answered: outstanding id cleared', (select keepalive_id is null from mc.player where name = 'A'));
select t.reset();
select t.eq('B never answered: after 600 ticks it is kicked', (select timed_out from mc.keepalive_due(900)), 1);
select t.eq('...with the timeout key', (select reason_nbt from mc.kick where conn_id = 2), proto.nbt_root(mc.disconnect_nbt('disconnect.timeout')));

------------------------------------------------------------------------------------------------ tick
select t.reset(); truncate mc.kick;
update mc.game_state set game_time = 19; update mc.player set keepalive_id = null, keepalive_sent_tick = 1000000;
select t.eq('tick returns the tick number', mc.tick(), 20::bigint);
select t.eq('tick 20: B''s earlier /tp (5 blocks) goes out as one relative move (20480/4096), then the game time',
  t.out(1), mc.pkt_move_entity_pos((select entity_id from mc.player where name = 'B'), 0, 0, 20480, 20, true) || mc.pkt_set_time(20));
select t.eq('tick log row written', (select players from mc.tick_log where tick = 20), 2);
select t.is_true('tick log has phase timings', (select ms_total >= 0 and ms_moves >= 0 and ms_visibility >= 0 from mc.tick_log where tick = 20));
select t.reset();
select mc.tick();
select t.eq('tick 21: idle, no packets', (select count(*) from mc.play_out)::int, 0);
select t.eq('the game clock advances one tick', (select game_time from mc.game_state), 21::bigint);

------------------------------------------------------------------------------------------------ input claim
select t.reset();
insert into mc.play_in (conn_id, packet_id, body) values (1, mc.sid('chat'), proto.string('claimed') || proto.i64(1) || proto.i64(2) || '\x00'::bytea || proto.varint(0) || '\x000000'::bytea || '\x00'::bytea);
select mc.tick();
select t.eq('the tick claims packets from the gateway-facing queue and processes them', (select count(*) from mc.chat_log where message = 'claimed')::int, 1);
select t.is_true('the gateway-facing queue is empty afterwards', not exists (select 1 from mc.play_in));
select t.is_true('and so is the claimed copy', not exists (select 1 from mc.play_in_work));
