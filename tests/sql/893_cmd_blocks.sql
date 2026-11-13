-- Block-position commands, components, weather, spawn points (sql/811, 813, 893 to 896).  Every fixture below is something the REAL vanilla 26.3 server did, recorded by
-- tests/e2e/cmd_blocks.py (the rows are generated from the recording: the command, the key and arguments of the error message and the cursor of its context line, the component
-- bytes of /title and /tellraw) and tests/e2e/weather_probe.py (the float steps of the weather levels).  The end-to-end comparison against a running server is `cmd_blocks.py compare`.
select (select count(*) from mc.cmd_node) > 100 as have_tree \gset
\if :have_tree
-- the argument parsers: the error key, its arguments and the cursor (the point the red context line underlines from)
select t.eq('parse error: ' || f.cmd, (select array[r.ex_key, coalesce(r.ex_args::text, 'null'), r.ex_cursor::text] from mc.cmd_parse(4, f.cmd) r), array[f.key, coalesce(f.args::jsonb::text, 'null'), f.cur::text])
  from (values
    ('setblock 0 -60 10 stone[foo=bar]', 'argument.block.property.unknown', '["minecraft:stone", "foo"]', 24),
    ('setblock 0 -60 10 oak_log[axis=q]', 'argument.block.property.invalid', '["minecraft:oak_log", "q", "axis"]', 31),
    ('setblock 0 -60 10 oak_log[axis]', 'argument.block.property.novalue', '["axis", "minecraft:oak_log"]', 30),
    ('setblock 0 -60 10 oak_log[axis=x', 'argument.block.property.unclosed', null, 32),
    ('setblock 0 -60 10 oak_log[axis=x,axis=y]', 'argument.block.property.duplicate', '["axis", "minecraft:oak_log"]', 33),
    ('setblock 0 -60 10 nonsense', 'argument.block.id.invalid', '["minecraft:nonsense"]', 18),
    ('setblock 0 -60 10 Stone', 'argument.block.id.invalid', '["minecraft:"]', 18),
    ('setblock 0 -60 10 #minecraft:logs', 'argument.block.tag.disallowed', null, 18),
    ('setblock 0 -60 10 ', 'command.unknown.argument', null, 17),
    ('setblock 0 -60', 'argument.pos3d.incomplete', null, 9),
    ('setblock 0 -60 x stone', 'parsing.int.expected', null, 15),
    ('setblock 0.5 -60 10 stone', 'parsing.int.invalid', '["0.5"]', 9),
    ('setblock ~ ^ ~ stone', 'argument.pos.mixed', null, 11),
    ('setblock 0 -60 10 stone foo', 'command.unknown.argument', null, 24),
    ('fill 0 -60 12 3 -58 14 minecraft:nonsense', 'argument.block.id.invalid', '["minecraft:nonsense"]', 23),
    ('fill 0 -60 12 3 -58 14 stone replace minecraft:nonsense', 'argument.block.id.invalid', '["minecraft:nonsense"]', 37),
    ('fill 0 -60 12 3 -58 14 stone replace #minecraft:nonsense', 'arguments.block.tag.unknown', '["minecraft:nonsense"]', 37),
    ('fill 0 -60 12 3 -58 14 stone replace oak_log[axis=q]', 'argument.block.property.invalid', '["minecraft:oak_log", "q", "axis"]', 50),
    ('fill 0 -60 12 3 -58 stone', 'parsing.int.expected', null, 20),
    ('spawnpoint Surv 5 -60 5 90', 'argument.rotation.incomplete', null, 24),
    ('spawnpoint Surv 5 -60', 'argument.pos3d.incomplete', null, 16),
    ('setworldspawn 3 -60 3 90', 'argument.rotation.incomplete', null, 22),
    ('setworldspawn x', 'parsing.int.expected', null, 14),
    ('setworldspawn 3 -60', 'argument.pos3d.incomplete', null, 14),
    ('setworldspawn 3 -60 3 90 a', 'parsing.double.expected', null, 25),
    ('weather rain 0', 'argument.time.tick_count_too_low', '[1, 0]', 14),
    ('weather rain -5', 'argument.time.tick_count_too_low', '[1, -5]', 15),
    ('weather rain x', 'parsing.float.expected', null, 13),
    ('weather', 'command.unknown.command', null, 7),
    ('weather snow', 'command.unknown.argument', null, 8),
    ('title Surv title {', 'argument.literal.incorrect', '["\""]', 18),
    ('title Surv title', 'command.unknown.command', null, 16),
    ('title Surv title 5', 'argument.component.invalid', '["Failed to parse either. First: Failed to parse either. First: Not a string; Second: Not a list: 5; Second: Not a map: 5"]', 17),
    ('title Surv title true', 'argument.component.invalid', '["Failed to parse either. First: Failed to parse either. First: Not a string; Second: Not a list: 1b; Second: Not a map: 1b"]', 17),
    ('title Surv title {"text":1}', 'argument.component.invalid', '["Failed to parse either. First: Failed to parse either. First: Not a string; Second: Not a list: {text:1}; Second: No matching codec found"]', 17),
    ('title Surv title {"extra":["a"]}', 'argument.component.invalid', '["Failed to parse either. First: Failed to parse either. First: Not a string; Second: Not a list: {extra:[\"a\"]}; Second: No matching codec found"]', 17),
    ('tellraw Surv {"text":"x","color":"nonsense"}', 'argument.component.invalid', '["Invalid color name: nonsense"]', 13),
    ('tellraw Surv {"text":"x","bold":"yes"}', 'argument.component.invalid', '["Not a number"]', 13),
    ('tellraw Surv', 'command.unknown.command', null, 12),
    ('tellraw Surv []', 'argument.component.invalid', '["Failed to parse either. First: Failed to parse either. First: Not a string; Second: List must have contents; Second: Not a map: []"]', 13),
    ('tellraw Surv {}', 'argument.component.invalid', '["Failed to parse either. First: Failed to parse either. First: Not a string; Second: Not a list: {}; Second: No matching codec found"]', 13),
    ('tellraw Surv 12', 'argument.component.invalid', '["Failed to parse either. First: Failed to parse either. First: Not a string; Second: Not a list: 12; Second: Not a map: 12"]', 13)) f(cmd, key, args, cur);

-- the block position, block state and block predicate values
select t.eq('block_pos absolute, relative, local', array[(mc.rd_blockpos('1 -60 5', 0)).val::text, (mc.rd_blockpos('~ ~1.5 ~-3', 0)).val::text, (mc.rd_blockpos('^ ^1 ^-2', 0)).val::text], array['["1", "-60", "5"]', '["~", "~1.5", "~-3"]', '["^", "^1", "^-2"]']);
select t.eq('block_state with properties is the full state name, in the registry order', (mc.rd_blockstate('oak_log[axis=x]', 0, false)).val ->> 'state', 'minecraft:oak_log[axis=x]');
select t.eq('block_state with properties of stairs keeps the default of the others', (mc.rd_blockstate('oak_stairs[facing=north,half=top]', 0, false)).val ->> 'state', 'minecraft:oak_stairs[facing=north,half=top,shape=straight,waterlogged=false]');
select t.eq('block_predicate with a tag and a property', (mc.rd_blockstate('#minecraft:logs[axis=x]', 0, true)).val, '{"tag": "minecraft:logs", "props": {"axis": "x"}}'::jsonb);

-- text components: the bytes vanilla sent (a title packet is the component's root tag; a /tellraw chat packet is the root tag and a false overlay byte)
create or replace function t.comp(p_snbt text) returns text language plpgsql as $f$
declare r mc.cmd_ap := mc.snbt_value(p_snbt, 0);
begin return encode(mc.comp_root(r.val, null), 'hex'); end $f$;
select t.eq(c.kind || ' component ' || c.src, t.comp(c.src), case when c.kind = 'tellraw' then substr(c.hex, 1, length(c.hex) - 2) else c.hex end)
  from (values
    ('title', '{"text":"Hi"}', '0800024869'),
    ('title', '"plain"', '080005706c61696e'),
    ('title', '["a",{"text":"b","color":"blue"},"c"]', '0a09000565787472610a00000002080005636f6c6f720004626c75650800047465787400016200080000000163000800047465787400016100'),
    ('title', '{"translate":"chat.type.text","with":["Surv","msg"]}', '0a09000477697468080000000200045375727600036d73670800097472616e736c617465000e636861742e747970652e7465787400'),
    ('title', '{"text":"x","color":"#ff8800"}', '0a080005636f6c6f720007234646383830300800047465787400017800'),
    ('title', '{"text":"x",}', '08000178'),
    ('title', '{"text":"a","extra":[{"text":"b"},"c"]}', '0a090005657874726108000000020001620001630800047465787400016100'),
    ('title', '{"text":"a","hover_event":{"action":"show_text","value":"v"}}', '0a080004746578740001610a000b686f7665725f6576656e74080006616374696f6e000973686f775f7465787408000576616c75650001760000'),
    ('title', '{"text":"a","click_event":{"action":"open_url","url":"https://example.com"}}', '0a0a000b636c69636b5f6576656e74080006616374696f6e00086f70656e5f75726c08000375726c001368747470733a2f2f6578616d706c652e636f6d000800047465787400016100'),
    ('title', '{"text":"a","insertion":"i","font":"minecraft:alt","underlined":true,"strikethrough":false,"obfuscated":true}', '0a01000a756e6465726c696e656401080009696e73657274696f6e0001690800047465787400016101000d737472696b657468726f7567680001000a6f62667573636174656401080004666f6e74000d6d696e6563726166743a616c7400'),
    ('title', '{"score":{"name":"Surv","objective":"o"}}', '080000'),
    ('title', '{"keybind":"key.jump"}', '0a0800076b657962696e6400086b65792e6a756d7000'),
    ('title', '{"nbt":"x","entity":"@s"}', '080000'),
    ('tellraw', '{"text":"x","color":"red"}', '0a080005636f6c6f720003726564080004746578740001780000'),
    ('tellraw', '{"translate":"commands.give.success.single","with":[1,"a","b"]}', '0a090004776974680a00000003030000000000010008000000016100080000000162000800097472616e736c617465001c636f6d6d616e64732e676976652e737563636573732e73696e676c650000'),
    ('tellraw', 'x', '0800017800'),
    ('tellraw', '{''text'':''single''}', '08000673696e676c6500'),
    ('tellraw', '{"text":"é ü \u00e9 \n x"}', '08000cc3a920c3bc20c3a9200a207800'),
    ('tellraw', '[{"text":"a"},{"text":"b"}]', '0a09000565787472610800000001000162080004746578740001610000'),
    ('tellraw', '{"text":""}', '08000000'),
    ('tellraw', '""', '08000000'),
    ('tellraw', '{"text":"a","color":"red","extra":[{"text":"b","color":"blue"}]}', '0a080005636f6c6f72000372656409000565787472610a00000001080005636f6c6f720004626c75650800047465787400016200080004746578740001610000'),
    ('tellraw', '{"text":"x","shadow_color":-1}', '0a03000c736861646f775f636f6c6f72ffffffff080004746578740001780000'),
    ('tellraw', '{"text":"x","shadow_color":[1.0,0.5,0.0,1.0]}', '0a03000c736861646f775f636f6c6f72ffff7f00080004746578740001780000')) c(kind, src, hex);

-- the HashMap order of NBT keys: the two orders recorded above come out of Java's bucket function
select t.eq('java hash order: text, bold -> text first', mc.java_hash_order(array['text', 'bold']), array['text', 'bold']);
select t.eq('java hash order: the recorded style keys', mc.java_hash_order(array['text', 'insertion', 'font', 'strikethrough', 'obfuscated', 'underlined']), array['underlined', 'insertion', 'text', 'strikethrough', 'obfuscated', 'font']);

-- the weather levels move by 0.01 as float32: the values the real server sent
select t.eq('rain level after 37 ticks is 0.3699999 (recorded)', round((select v from (select (array_agg(x order by o))[37] as v from (select o, sum(0.01::real) over (order by o)::real as x from generate_series(1, 40) o) q) q2)::float8::numeric, 7), 0.3699999);

-- the weather clock (mc.weather_tick): rain for 5 ticks, then it stops raining; the levels and the game events
delete from mc.player;
select mc.weather_set(0, 5, true, false);
update mc.game_state set rain_level = 0, thunder_level = 0;
create temp table _lv (tk int, rain real, raining boolean, rt int);
do $f$ begin for i in 1 .. 8 loop perform mc.weather_tick(i); insert into _lv select i, rain_level, raining, rain_time from mc.game_state; end loop; end $f$;
select t.eq('weather: raining for the 5 ticks of the duration, then not', (select array_agg(raining order by tk) from _lv), array[true, true, true, true, false, false, false, false]);
select t.eq('weather: the level rises 4 ticks, then falls', (select array_agg(round(rain::numeric, 2) order by tk) from _lv), array[0.01, 0.02, 0.03, 0.04, 0.03, 0.02, 0.01, 0.00]);
-- /weather clear 100: both flags off, then (recorded) the pinned counters turn rain and thunder on when the clear time is over
select mc.weather_set(2, 0, false, false);
update mc.game_state set rain_level = 0, thunder_level = 0, raining = false, thundering = false;
delete from _lv;
do $f$ begin for i in 1 .. 5 loop perform mc.weather_tick(i); insert into _lv select i, rain_level, raining, rain_time from mc.game_state; end loop; end $f$;
select t.eq('weather: after a clear period the weather turns to rain (recorded quirk)', (select array_agg(raining order by tk) from _lv), array[false, false, true, true, true]);
select mc.weather_set(0, 0, false, false);
\else
\echo 'NOTE: no command tree: tests/sql/893_cmd_blocks.sql skipped'
\endif
