-- The commands that run on the parse of the graph (sql/811-815): selectors, /seed /me /msg /say /help /gamerule /clear /give /gamemode /tp /op /deop /whitelist /kill,
-- the operator broadcast of feedback, the permission levels, the error reports.  The byte-for-byte comparison with the real server is tests/e2e/compare_commands.py;
-- here the expected packets are built from the component builders whose shapes that comparison verified.
\ir _harness.sql

create or replace function t.out(conn int) returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = conn $$;
create or replace function t.reset() returns void language sql as $$ truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick $$;
create or replace function t.cmd(conn int, txt text) returns void language sql as $$ select mc.run_command(conn, txt) $$;
create or replace function t.say(conn int, root bytea) returns bytea language sql as $$ select mc.pkt_system_chat(root) $$;
create or replace function t.fail(inner_fields bytea) returns bytea language sql as $$ select mc.pkt_system_chat(proto.nbt_root(mc.tc_failure(inner_fields))) $$;
create or replace function t.ok(fields bytea) returns bytea language sql as $$ select mc.pkt_system_chat(proto.nbt_root(fields)) $$;

select t.reset(); truncate mc.visible; delete from mc.player; delete from mc.op; delete from mc.chat_log; delete from mc.ban; delete from mc.whitelist; delete from mc.game_rule;
update mc.server_property set value = 'false' where key = 'white-list'; update mc.server_property set value = '20' where key = 'max-players';
update mc.server_property set value = 'creative' where key = 'gamemode'; update mc.server_property set value = 'peaceful' where key = 'difficulty';
update mc.game_state set game_time = 0, day_time = 0, raining = false, thundering = false;
select mc.on_join(1, '00000000-0000-0000-0000-000000008101', 'Ann');     -- operator, level 4
select mc.on_join(2, '00000000-0000-0000-0000-000000008102', 'Bea');     -- plain player
select mc.on_join(3, '00000000-0000-0000-0000-000000008103', 'Cid');     -- operator, level 2
select mc.on_join(4, '00000000-0000-0000-0000-000000008104', 'Dan');     -- plain player, far away
insert into mc.op values ('00000000-0000-0000-0000-000000008101', 'Ann', 4, false), ('00000000-0000-0000-0000-000000008103', 'Cid', 2, false);
update mc.player set x = 0, y = 64, z = 0 where name = 'Ann'; update mc.player set x = 3, y = 64, z = 0 where name = 'Bea';
update mc.player set x = 10, y = 64, z = 0 where name = 'Cid'; update mc.player set x = 100, y = 64, z = 0 where name = 'Dan';
select mc.refresh_visibility(); select t.reset();

create or replace function t.pl(n text) returns bytea language sql as $$ select mc.tc_player(uuid, name) from mc.player where name = n $$;

------------------------------------------------------------------------------------------------ selectors
select t.eq('@a: every player in join order', (select array_agg(name order by entity_id) from mc.sel_players('{"kind":"a","sort":"arbitrary"}', (select p from mc.player p where name = 'Ann') )), array['Ann','Bea','Cid','Dan']);
select t.eq('@a[distance=..5] from Ann', (select array_agg(name order by entity_id) from mc.sel_players((mc.sel_parse('@a[distance=..5]', 0, true)).val, (select p from mc.player p where name = 'Ann'))), array['Ann','Bea']);
select t.eq('@a[distance=5..50]', (select array_agg(name order by entity_id) from mc.sel_players((mc.sel_parse('@a[distance=5..50]', 0, true)).val, (select p from mc.player p where name = 'Ann'))), array['Cid']);
select t.eq('@a[limit=2,sort=furthest]', (select array_agg(name order by name) from mc.sel_players((mc.sel_parse('@a[limit=2,sort=furthest]', 0, true)).val, (select p from mc.player p where name = 'Ann'))), array['Cid','Dan']);
select t.eq('@p is the nearest other-or-self player', (select array_agg(name) from mc.sel_players((mc.sel_parse('@p', 0, true)).val, (select p from mc.player p where name = 'Bea'))), array['Bea']);
select t.eq('@a[name=!Ann,limit=1]', (select array_agg(name) from mc.sel_players((mc.sel_parse('@a[name=!Ann,limit=1]', 0, true)).val, (select p from mc.player p where name = 'Ann'))), array['Bea']);
select t.eq('@a[gamemode=creative] / !creative', (select count(*) from mc.sel_players((mc.sel_parse('@a[gamemode=creative]', 0, true)).val, (select p from mc.player p where name = 'Ann')))::int, 4);
select t.eq('...', (select count(*) from mc.sel_players((mc.sel_parse('@a[gamemode=!creative]', 0, true)).val, (select p from mc.player p where name = 'Ann')))::int, 0);
select t.eq('@e[type=player] is every player, @e[type=zombie] nobody', (select count(*) from mc.sel_players((mc.sel_parse('@e[type=player]', 0, true)).val, (select p from mc.player p where name = 'Ann')))::int, 4);
select t.eq('...', (select count(*) from mc.sel_players((mc.sel_parse('@e[type=zombie]', 0, true)).val, (select p from mc.player p where name = 'Ann')))::int, 0);
select t.eq('@r[limit=2] picks two distinct players', (select count(distinct name) from mc.sel_players((mc.sel_parse('@r[limit=2]', 0, true)).val, (select p from mc.player p where name = 'Ann')))::int, 2);
select t.eq('a name is case-insensitive', (select array_agg(name) from mc.sel_players((mc.sel_parse('bea', 0, false)).val, (select p from mc.player p where name = 'Ann'))), array['Bea']);
select t.eq('selector parse error: unknown option', (select (mc.sel_parse('@a[foo=1]', 0, true)).ex_key), 'argument.entity.options.unknown');
select t.eq('...cursor at the option name', (select (mc.sel_parse('@a[foo=1]', 0, true)).ex_cursor), 3);
select t.eq('selector not allowed below level 2', (select (mc.sel_parse('@a', 0, false)).ex_key), 'argument.entity.selector.not_allowed');
select t.eq('limit twice is inapplicable', (select (mc.sel_parse('@a[limit=1,limit=2]', 0, true)).ex_key), 'argument.entity.options.inapplicable');
select t.eq('a range that is swapped', (select (mc.sel_parse('@a[distance=5..1]', 0, true)).ex_key), 'argument.range.swapped');

------------------------------------------------------------------------------------------------ permission levels and errors
select t.cmd(2, 'seed');
select t.eq('a player without the level gets the unknown-command pair (what vanilla says: the command is not in the player''s tree)', (select count(*) from mc.play_out where conn_id = 2)::int, 2);
select t.eq('...the first is the red failure', (select data from mc.play_out where conn_id = 2 order by seq limit 1), t.fail(mc.tc_translate('command.unknown.command')));
select t.eq('...the second underlines the input and marks the cursor', (select data from mc.play_out where conn_id = 2 order by seq offset 1 limit 1),
            t.fail(mc.cmd_context_fields('seed', 0)));
select t.reset();
select t.cmd(1, 'gamemode');
select t.eq('an incomplete command: the context ends at the cursor', t.out(1), t.fail(mc.tc_translate('command.unknown.command')) || t.fail(mc.cmd_context_fields('gamemode', 8)));
select t.reset();
select t.cmd(1, 'gamemode foo');
select t.eq('an invalid argument names it', t.out(1), t.fail(mc.tc_translate_strs('argument.gamemode.invalid', array['foo'])) || t.fail(mc.cmd_context_fields('gamemode foo', 12)));
select t.reset();
select t.eq('the context shows at most ten characters before the cursor, with an ellipsis', encode(mc.cmd_context_fields('give Bea stone 0', 15), 'hex'),
            encode(proto.cat(array[proto.nbt_comp('click_event', proto.nbt_str('action', 'suggest_command'), proto.nbt_str('command', '/give Bea stone 0')), proto.nbt_str('color', 'gray'),
              proto.nbt_list_comp('extra', array[proto.nbt_str('', '...'), proto.nbt_str('', 'Bea stone '), proto.cat(array[proto.nbt_str('color', 'red'), proto.nbt_byte('underlined', 1), proto.nbt_str('text', '0')]),
                proto.cat(array[proto.nbt_str('color', 'red'), proto.nbt_byte('italic', 1), proto.nbt_str('translate', 'command.context.here')])]), proto.nbt_str('text', '')]), 'hex'));
select t.cmd(1, 'fill 0 0 0 1 1 1 stone');
select t.eq('a command of the graph that dbcraft does not implement is said so, not ignored', t.out(1), t.fail(proto.nbt_str('text', '/fill is not implemented in dbcraft')));
select t.reset();

------------------------------------------------------------------------------------------------ /seed /me /msg /say
update mc.server_property set value = '2013354044074181219' where key = 'level-seed';
select t.cmd(1, 'seed');
select t.eq('/seed: the seed with copy-to-clipboard (shape verified against the real server), only to the executor', t.out(1),
  t.ok(mc.tc_translate('commands.seed.success', array[proto.cat(array[proto.nbt_list_comp('with', array[proto.cat(array[
      proto.nbt_comp('click_event', proto.nbt_str('action', 'copy_to_clipboard'), proto.nbt_str('value', '2013354044074181219')), proto.nbt_str('color', 'green'),
      proto.nbt_str('insertion', '2013354044074181219'), proto.nbt_str('text', '2013354044074181219'),
      proto.nbt_comp('hover_event', proto.nbt_str('action', 'show_text'), proto.nbt_comp('value', proto.nbt_str('translate', 'chat.copy.click')))])]),
    proto.nbt_str('translate', 'chat.square_brackets')])])));
select t.eq('...nothing for the other players (not broadcast to operators)', (select count(*) from mc.play_out where conn_id <> 1)::int, 0);
select t.reset();
update mc.server_property set value = 'hello' where key = 'level-seed';
select t.eq('a text seed is hashed like String.hashCode', mc.world_seed_get(), 99162322::bigint);
update mc.server_property set value = '' where key = 'level-seed';

select t.cmd(2, 'me waves');
select t.eq('/me: a disguised_chat of the emote type to everybody, in player order', (select array_agg(conn_id order by seq) from mc.play_out), array[1,2,3,4]);
select t.eq('...the bytes', t.out(3), mc.pkt_disguised_chat_root(mc.nbt_root_text('waves'), mc.chat_type_id('minecraft:emote_command'), t.pl('Bea')));
select t.reset();
select t.cmd(2, 'me');
select t.eq('/me without text is an incomplete command', (select count(*) from mc.play_out where conn_id = 2)::int, 2);
select t.reset();
select t.cmd(2, 'msg Cid hi there');
select t.eq('/msg: the sender gets the outgoing line (with the target name), the target the incoming one', t.out(2),
            mc.pkt_disguised_chat_root(mc.nbt_root_text('hi there'), mc.chat_type_id('minecraft:msg_command_outgoing'), t.pl('Bea'), t.pl('Cid')));
select t.eq('...', t.out(3), mc.pkt_disguised_chat_root(mc.nbt_root_text('hi there'), mc.chat_type_id('minecraft:msg_command_incoming'), t.pl('Bea')));
select t.eq('...nobody else hears it', (select count(*) from mc.play_out where conn_id in (1, 4))::int, 0);
select t.reset();
select t.cmd(2, 'w Cid psst');
select t.eq('/w and /tell are /msg (aliases are redirects in the graph)', (select count(*) from mc.play_out)::int, 2);
select t.reset();
select t.cmd(1, 'msg @a all');
select t.eq('/msg @a: per target the outgoing line then the incoming line', (select count(*) from mc.play_out)::int, 4 + 4);
select t.eq('...the sender''s own stream alternates outgoing for each of the four', (select count(*) from mc.play_out where conn_id = 1)::int, 5);
select t.reset();
select t.cmd(2, 'msg @a x');
select t.eq('a player without level 2 cannot use selectors', t.out(2), t.fail(mc.tc_translate('argument.entity.selector.not_allowed')) || t.fail(mc.cmd_context_fields('msg @a x', 4)));
select t.reset();
select t.cmd(1, 'msg Nobody hi');
select t.eq('/msg to nobody: one red line, no context line', t.out(1), t.fail(mc.tc_translate('argument.entity.notfound.player')));
select t.reset();
select t.cmd(1, 'say hello');
select t.eq('/say: the say_command chat type to everybody', t.out(4), mc.pkt_disguised_chat_root(mc.nbt_root_text('hello'), mc.chat_type_id('minecraft:say_command'), t.pl('Ann')));
select t.reset();
select t.cmd(1, 'say @a[name=Bea] hi');
select t.eq('/say with a selector: names resolved into the text (an empty parent, the name, the rest as extra)', t.out(4),
  mc.pkt_disguised_chat_root(proto.nbt_root(proto.nbt_list_comp('extra', array[t.pl('Bea'), proto.nbt_str('', ' hi')]), proto.nbt_str('text', '')),
                             mc.chat_type_id('minecraft:say_command'), t.pl('Ann')));
select t.reset();
select t.cmd(1, 'say x @a[name=zzz] y');
select t.eq('...an empty selection is an empty string; a list of plain strings is a list of strings', t.out(4),
  mc.pkt_disguised_chat_root(proto.nbt_root(proto.nbt_list_str('extra', array['', ' y']), proto.nbt_str('text', 'x ')), mc.chat_type_id('minecraft:say_command'), t.pl('Ann')));
select t.reset();

------------------------------------------------------------------------------------------------ the operator broadcast
select t.cmd(1, 'gamerule keep_inventory true');
select t.eq('a state-changing command: the executor gets the feedback', (select data from mc.play_out where conn_id = 1), t.ok(mc.tc_translate_strs('commands.gamerule.set', array['keep_inventory', 'true'])));
select t.eq('...another operator gets it wrapped in chat.type.admin (gray, italic)', (select data from mc.play_out where conn_id = 3),
  t.ok(proto.cat(array[proto.nbt_list_comp('with', array[t.pl('Ann'), mc.tc_translate_strs('commands.gamerule.set', array['keep_inventory', 'true'])]),
                       proto.nbt_str('color', 'gray'), proto.nbt_byte('italic', 1), proto.nbt_str('translate', 'chat.type.admin')])));
select t.eq('...players that are not operators get nothing', (select count(*) from mc.play_out where conn_id in (2, 4))::int, 0);
select t.eq('...the value is stored where a world import and the survival module read it', (select value from mc.game_rule where name = 'minecraft:keep_inventory'), 'true');
select t.reset();
select t.cmd(1, 'gamerule keep_inventory true');
select t.eq('setting the value it has is a failure', t.out(1), t.fail(mc.tc_translate_strs('commands.gamerule.not_set', array['keep_inventory', 'true'])));
select t.reset();
select t.cmd(1, 'gamerule keep_inventory');
select t.eq('querying says the value, to the executor only', t.out(1), t.ok(mc.tc_translate_strs('commands.gamerule.query', array['keep_inventory', 'true'])));
select t.eq('...', (select count(*) from mc.play_out where conn_id <> 1)::int, 0);
select t.reset();
select t.cmd(1, 'gamerule random_tick_speed -1');
select t.eq('a value below the range of the graph is refused with the vanilla text', t.out(1), t.fail(mc.tc_translate_json('argument.integer.low', '[0, -1]')) || t.fail(mc.cmd_context_fields('gamerule random_tick_speed -1', 27)));
select t.reset();
select t.cmd(1, 'gamerule send_command_feedback false');
select t.cmd(1, 'gamerule keep_inventory false');
select t.eq('with send_command_feedback off nothing is said, to anybody', (select count(*) from mc.play_out)::int, 0);
select t.eq('...but the rule changed', mc.gamerule_get('keep_inventory'), 'false');
select t.cmd(1, 'gamerule send_command_feedback true');
select t.eq('...and turning it back on is answered', (select count(*) from mc.play_out where conn_id = 1)::int, 1);
select t.reset();
select t.eq('every rule of the table has a default of its type', (select count(*) from mc.gamerule_default where (vtype = 'bool' and default_value not in ('true', 'false')) or (vtype = 'int' and default_value !~ '^-?[0-9]+$'))::int, 0);
select t.eq('...58 rules', (select count(*) from mc.gamerule_default)::int, 58);

------------------------------------------------------------------------------------------------ /help
select t.cmd(2, 'help');
select t.eq('/help for a plain player: the ten lines of the level-0 graph', (select count(*) from mc.play_out where conn_id = 2)::int, 10);
select t.eq('...first line', (select data from mc.play_out where conn_id = 2 order by seq limit 1), t.say(2, mc.nbt_root_text('/me <action>')));
select t.eq('...an alias line', (select data from mc.play_out where conn_id = 2 order by seq offset 4 limit 1), t.say(2, mc.nbt_root_text('/tell -> msg')));
select t.reset();
select t.cmd(1, 'help gamemode');
select t.eq('/help <command>', t.out(1), t.say(1, mc.nbt_root_text('/gamemode <gamemode> [<target>]')));
select t.reset();
select t.cmd(1, 'help gamemode creative');
select t.eq('...follows the typed arguments', t.out(1), t.say(1, mc.nbt_root_text('/gamemode creative [<target>]')));
select t.reset();
select t.cmd(1, 'help nosuch');
select t.eq('...unknown', t.out(1), t.fail(mc.tc_translate('commands.help.failed')));
select t.reset();
select t.cmd(2, 'help gamemode');
select t.eq('...a command the player cannot use is unknown too', t.out(2), t.fail(mc.tc_translate('commands.help.failed')));
select t.reset();
select t.eq('smart usage of /difficulty (optional alternatives)', (select mc.cmd_usage(c.child, 4, false, false) from mc.cmd_child c join mc.cmd_node n on n.id = c.child where c.parent = 0 and n.name = 'difficulty'), 'difficulty [peaceful|easy|normal|hard]');
select t.eq('smart usage of /kill', (select mc.cmd_usage(c.child, 4, false, false) from mc.cmd_child c join mc.cmd_node n on n.id = c.child where c.parent = 0 and n.name = 'kill'), 'kill [<targets>]');
select t.eq('smart usage of /xp (an alias)', (select mc.cmd_usage(c.child, 4, false, false) from mc.cmd_child c join mc.cmd_node n on n.id = c.child where c.parent = 0 and n.name = 'xp'), 'xp -> experience');
select t.eq('smart usage of /give', (select mc.cmd_usage(c.child, 4, false, false) from mc.cmd_child c join mc.cmd_node n on n.id = c.child where c.parent = 0 and n.name = 'give'), 'give <targets> <item> [<count>]');
select t.eq('a node above the level has no usage', (select mc.cmd_usage(c.child, 0, false, false) from mc.cmd_child c join mc.cmd_node n on n.id = c.child where c.parent = 0 and n.name = 'give'), null);

------------------------------------------------------------------------------------------------ /gamemode /tp /give /clear
select t.cmd(1, 'gamemode survival @a');
select t.eq('/gamemode @a changes everybody', (select count(*) from mc.player where gamemode = 0)::int, 4);
select t.eq('...the executor is told about itself, the others about each', (select count(*) from mc.play_out where conn_id = 1 and data = t.ok(mc.tc_translate('commands.gamemode.success.self', array[mc.tc_translate('gameMode.survival')])))::int, 1);
select t.eq('...a target is told "Your game mode has been updated"', (select count(*) from mc.play_out where conn_id = 4 and data = t.ok(mc.tc_translate('gameMode.changed', array[mc.tc_translate('gameMode.survival')])))::int, 1);
select t.reset();
select t.cmd(1, 'gamemode survival @a');
select t.eq('a game mode that does not change says nothing (verified against vanilla)', (select count(*) from mc.play_out)::int, 0);
select t.cmd(1, 'gamemode creative @a[name=Bea]');
select t.eq('/gamemode creative @a[name=Bea]', (select array_agg(name order by name) from mc.player where gamemode = 1), array['Bea']);
select t.cmd(1, 'gamemode survival Bea');
select t.reset();
update mc.player set x = 0, y = 64, z = 0, yaw = 90 where name = 'Ann';
select t.cmd(1, 'tp Dan ~ ~1 ~2');
select t.eq('/tp: ~ is relative to the EXECUTOR', (select array[x, y, z] from mc.player where name = 'Dan'), array[0::float8, 65, 2]);
select t.eq('...the target gets position packets with relative flags (x y z and their velocities) and, because y is relative, an absolute one', (select count(*) from mc.play_out where conn_id = 4)::int, 2);
select t.reset();
select t.cmd(1, 'tp Dan 1 2 3');
select t.eq('integer x and z are centred on the block', (select array[x, y, z] from mc.player where name = 'Dan'), array[1.5::float8, 2, 3.5]);
select t.eq('absolute coordinates: one packet, flags 0x18 (verified)', t.out(4), mc.pkt_player_position((select teleport_id from mc.player where name = 'Dan'), 1.5, 2, 3.5, 0, 0, 0, 0, 0, 24));
select t.reset();
select t.cmd(1, 'tp Bea Cid');
select t.eq('/tp <target> <destination>', (select array[x, y, z] from mc.player where name = 'Bea'), (select array[x, y, z] from mc.player where name = 'Cid'));
select t.reset();
select t.cmd(1, 'tp @a Ann');
select t.eq('/tp @a Ann: everybody at Ann''s place', (select count(*) from mc.player where x = 0 and y = 64 and z = 0)::int, 4);
select t.eq('...multiple targets: "Teleported 4 entities to Ann"', (select count(*) from mc.play_out where conn_id = 1 and data = t.ok(mc.tc_translate('commands.teleport.success.entity.multiple', array[mc.tc_arg_int(4), t.pl('Ann')])))::int, 1);
select t.reset();
select t.cmd(1, 'tp Bea @a');
select t.eq('a destination must be one entity: all alternatives fail, so the argument is "incorrect"', (select count(*) from mc.play_out where conn_id = 1)::int, 2);
select t.reset();
select t.cmd(1, 'give @a minecraft:stone 3');
select t.eq('/give @a gives to everybody', (select count(*) from mc.inventory_slot where item = 'minecraft:stone' and count = 3)::int, 4);
select t.eq('...one "Gave 3 [Stone] to 4 players" for the executor', (select count(*) from mc.play_out where conn_id = 1 and data = t.ok(mc.tc_translate('commands.give.success.multiple', array[mc.tc_arg_int(3), mc.tc_item('minecraft:stone'), mc.tc_arg_int(4)])))::int, 1);
select t.reset();
select t.cmd(1, 'give Bea minecraft:stone 7000');
select t.eq('/give above 100 stacks is refused (6400 for a 64 stack)', t.out(1), t.fail(mc.tc_translate('commands.give.failed.toomanyitems', array[mc.tc_arg_int(6400), mc.tc_item('minecraft:stone')])));
select t.reset();
select t.cmd(1, 'clear Bea minecraft:stone 2');
select t.eq('/clear removes the count it is given', (select count from mc.inventory_slot where player = (select uuid from mc.player where name = 'Bea') and item = 'minecraft:stone'), 1::smallint);
select t.eq('...the target gets the changed slot and the crafting result slot (state ids 2 and 3 after the join content and the earlier /give)',
            (select count(*) from mc.play_out where conn_id = 2)::int, 2);
select t.reset();
select t.cmd(1, 'clear Bea minecraft:stone 0');
select t.eq('maxCount 0 only counts: "Found 1 matching item(s) on player Bea", nothing is sent to Bea', t.out(1),
            t.ok(mc.tc_translate('commands.clear.test.single', array[mc.tc_arg_int(1), t.pl('Bea')])));
select t.eq('...', (select count(*) from mc.play_out where conn_id = 2)::int, 0);
select t.reset();
select t.cmd(1, 'clear @a');
select t.eq('/clear @a empties everybody', (select count(*) from mc.inventory_slot)::int, 0);
select t.eq('...and says it with the totals (3 x 4 - 2 = 10 items, 4 players) as a list of ints, after the slot updates', (select data from mc.play_out where conn_id = 1 order by seq desc limit 1), t.ok(mc.tc_translate_json('commands.clear.success.multiple', '[10, 4]')));
select t.reset();
select t.cmd(1, 'clear Bea');
select t.eq('nothing to clear: the failure names the player', t.out(1), t.fail(mc.tc_translate('clear.failed.single', array[t.pl('Bea')])));
select t.reset();

------------------------------------------------------------------------------------------------ /op /deop and the command tree of the level
select t.cmd(1, 'op Bea');
select t.is_true('/op: the new operator gets entity_event 24+level, then the command tree of level 4 (and then the broadcast, being one now)',
  position(mc.pkt_entity_event((select entity_id from mc.player where name = 'Bea'), 28) || mc.pkt_commands(4) in t.out(2)) = 1);
select t.eq('...Bea is an operator at the level from op-permission-level', (select level from mc.op where name = 'Bea'), 4);
select t.eq('...the executor is told', (select count(*) from mc.play_out where conn_id = 1 and data = t.ok(mc.tc_translate_strs('commands.op.success', array['Bea'])))::int, 1);
select t.eq('...the other operator sees the broadcast, and so does Bea (she is one now)', (select count(*) from mc.play_out where conn_id = 3)::int, 1);
select t.reset();
select t.cmd(1, 'op Bea');
select t.eq('/op on an operator fails', t.out(1), t.fail(mc.tc_translate('commands.op.failed')));
select t.reset();
select t.cmd(1, 'deop Bea');
select t.eq('/deop: entity_event 24 and the level-0 tree', t.out(2), mc.pkt_entity_event((select entity_id from mc.player where name = 'Bea'), 24) || mc.pkt_commands(0));
select t.reset();
select t.cmd(1, 'deop Bea');
select t.eq('/deop on a player who is not one fails', t.out(1), t.fail(mc.tc_translate('commands.deop.failed')));
select t.reset();
select t.cmd(3, 'op Dan');
select t.eq('level 2 cannot /op (it needs 3): unknown command', (select count(*) from mc.play_out where conn_id = 3)::int, 2);
select t.reset();

------------------------------------------------------------------------------------------------ /whitelist, /list, /kill
select t.cmd(1, 'whitelist add Dan');
select t.eq('/whitelist add', (select count(*) from mc.whitelist)::int, 1);
select t.cmd(1, 'whitelist add Dan');
select t.eq('...again: "Player is already whitelisted"', (select data from mc.play_out where conn_id = 1 order by seq desc limit 1), t.fail(mc.tc_translate('commands.whitelist.add.failed')));
select t.reset();
select t.cmd(1, 'whitelist list');
select t.eq('/whitelist list', t.out(1), t.ok(mc.tc_translate('commands.whitelist.list', array[mc.tc_arg_int(1), mc.tc_arg_str('Dan')])));
select t.reset();
select t.cmd(1, 'whitelist on');
select t.cmd(1, 'whitelist on');
select t.eq('/whitelist on twice: the second says "already on"', (select data from mc.play_out where conn_id = 1 order by seq desc limit 1), t.fail(mc.tc_translate('commands.whitelist.alreadyOn')));
select t.cmd(1, 'whitelist off');
select t.reset();
select t.cmd(1, 'list');
select t.eq('/list', (select count(*) from mc.play_out where conn_id = 1)::int, 1);
select t.reset();
select t.cmd(1, 'list uuids');
select t.is_true('/list uuids carries name and uuid of each player as translate arguments', position('commands.list.nameAndId'::bytea in t.out(1)) > 0);
select t.reset();
select t.cmd(1, 'kill nosuch');
select t.eq('/kill with nobody found', t.out(1), t.fail(mc.tc_translate('argument.entity.notfound.entity')));
select t.reset();
select t.cmd(1, 'kill Dan');
select t.eq('/kill without the survival module says so and kills nobody', (select count(*) from mc.player where health > 0)::int, 4) where to_regprocedure('mc.kill_players(uuid[])') is null;
select t.reset();
create or replace function mc.kill_players(p_uuids uuid[]) returns int language sql as $$ update mc.player set health = 0 where uuid = any (p_uuids) returning 1 $$;
select t.cmd(1, 'kill Dan');
select t.eq('/kill calls the survival module''s mc.kill_players, then answers "Killed Dan"', t.out(1), t.ok(mc.tc_translate('commands.kill.success.single', array[t.pl('Dan')])));
select t.eq('...the victim was handed over', (select health from mc.player where name = 'Dan'), 0::real);
drop function mc.kill_players(uuid[]);
select t.reset();

------------------------------------------------------------------------------------------------ robustness
select t.cmd(1, 'msg @a[ x');
select t.is_true('malformed selectors never raise', true);
select t.cmd(1, repeat('a', 5000));
select t.cmd(1, 'tp ' || repeat('~ ', 200));
select t.cmd(1, '');
select t.is_true('a long or empty command does not raise either', true);
select t.cmd(999, 'list');
select t.is_true('...nor does a command from a connection without a player', true);
