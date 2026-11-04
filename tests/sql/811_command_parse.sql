-- The parser that walks the command graph (sql/811): which exception is reported and where its cursor is (the cursor selects what vanilla underlines in red).
-- Every row is a case whose answer was read from the real 26.3 server (tests/e2e/compare_commands.py compares the whole messages byte for byte).
\ir _harness.sql

select count(*) > 0 as loaded from mc.cmd_node \gset
\if :loaded
  create temp table cases (lvl int, input text, key text, cursor int);
  insert into cases values
    (4, 'gamemode foo',                    'argument.gamemode.invalid', 12),
    (4, 'gamemode',                        'command.unknown.command', 8),
    (4, 'gamemode survival Bob extra',     'command.unknown.argument', 22),
    (4, 'seed extra',                      'command.unknown.argument', 5),
    (4, 'give Bob stone 0',                'argument.integer.low', 15),
    (4, 'give Bob stone x',                'parsing.int.expected', 15),
    (4, 'give Bob foo',                    'argument.item.id.invalid', 9),
    (4, 'give Bob STONE',                  'argument.item.id.invalid', 9),
    (4, 'clear Bob foo',                   'argument.item.id.invalid', 13),
    (4, 'tp 1 2 x',                        'command.unknown.argument', 5),
    (4, 'tp Bob 1 2',                      'command.unknown.argument', 7),
    (4, 'msg @a[nonsense=1] x',            'argument.entity.options.unknown', 7),
    (4, 'msg @a[ x',                       'argument.entity.options.valueless', 8),
    (4, 'msg @x hi',                       'argument.entity.selector.unknown', 5),
    (4, 'msg @ x',                         'argument.entity.selector.unknown', 5),
    (4, 'msg @e x',                        'argument.player.entities', 0),
    (4, 'msg 00000000-0000-0000-0000-000000000001 x', 'argument.player.entities', 0),
    (4, 'msg @a[name=Bob]x',               'command.expected.separator', 16),
    (4, 'msg @a[name=Bob x',               'argument.entity.options.unterminated', 16),
    (4, 'msg @a[limit=0] x',               'argument.entity.options.limit.toosmall', 13),
    (4, 'msg @a[limit=x] x',               'parsing.int.expected', 13),
    (4, 'msg @a[sort=foo] x',              'argument.entity.options.sort.irreversible', 12),
    (4, 'msg @a[distance=x] x',            'argument.range.empty', 16),
    (4, 'msg @a[distance=5..1] x',         'argument.range.swapped', 16),
    (4, 'msg @a[distance=-1] x',           'argument.entity.options.distance.negative', 16),
    (4, 'msg @a[level=1.5] x',             'parsing.int.invalid', 13),
    (4, 'msg @a[gamemode=foo] x',          'argument.entity.options.mode.invalid', 16),
    (4, 'msg @a[gamemode=!foo] x',         'argument.entity.options.mode.invalid', 16),
    (4, 'msg @a[type=!foo] x',             'argument.entity.options.type.invalid', 12),
    (4, 'msg @a[name=Bob,name=Cy] x',      'argument.entity.options.inapplicable', 16),
    (4, 'msg @a[limit=1,limit=2] x',       'argument.entity.options.inapplicable', 15),
    (4, 'msg @s[limit=1] x',               'argument.entity.options.inapplicable', 7),
    (4, 'msg @a[name="Bob] x',             'parsing.quote.expected.end', 19),
    (4, 'msg @n x',                        'argument.player.entities', 0),
    (4, 'gamerule pvp xyz',                'parsing.bool.invalid', 13),
    (4, 'gamerule random_tick_speed -1',   'argument.integer.low', 27),
    (4, 'gamerule fire_spread_radius_around_player -2', 'argument.integer.low', 42),
    (4, 'gamerule nosuchrule',             'command.unknown.argument', 9),
    (4, 'gamerule keepInventory',          'command.unknown.argument', 9),
    (4, 'gamerule',                        'command.unknown.command', 8),
    (4, 'list ',                           'command.unknown.argument', 4),
    (4, 'list foo',                        'command.unknown.argument', 5),
    (4, 'kill Op4 Op4',                    'command.unknown.argument', 9),
    (4, 'time query daytime',              'argument.resource.not_found', 18),
    (4, 'time',                            'command.unknown.command', 4),
    (4, 'difficulty xyz',                  'command.unknown.argument', 11),
    (4, 'nosuchcommand',                   'command.unknown.command', 0),
    (0, 'seed',                            'command.unknown.command', 0),
    (0, 'fill 0 0 0 1 1 1 stone',          'command.unknown.command', 0),
    (0, 'say hi',                          'command.unknown.command', 0),
    (0, 'msg @a x',                        'argument.entity.selector.not_allowed', 4),
    (0, 'msg @p x',                        'argument.entity.selector.not_allowed', 4),
    (1, 'gamemode creative',               'command.unknown.command', 0),
    (2, 'ban Bob',                         'command.unknown.command', 0),
    (2, 'op Bob',                          'command.unknown.command', 0),
    (3, 'stop',                            'command.unknown.command', 0),
    (3, 'ban',                             'command.unknown.command', 3);
  select t.eq(lvl || ' ' || input || ': ' || key || ' at ' || cursor, (r).ex_key || ' at ' || (r).ex_cursor, key || ' at ' || cursor)
    from (select c.*, mc.cmd_parse(c.lvl, c.input) r from cases c) q;

  -- inputs that parse: the signature of the path and the arguments
  create function pg_temp.sig(p_lvl int, p_input text) returns text language sql as $$
    select string_agg(coalesce(t.name, n.name), '/' order by u.o) from unnest((mc.cmd_parse(p_lvl, p_input)).path) with ordinality u(id, o)
      join mc.cmd_node n on n.id = u.id left join mc.cmd_node t on t.id = n.redirect $$;
  select t.eq('gamemode survival Bob', pg_temp.sig(4, 'gamemode survival Bob'), 'gamemode/gamemode/target');
  select t.eq('tp is an alias: its path is the one of /teleport', pg_temp.sig(4, 'tp Bob 1 2 3'), 'teleport/targets/location');
  select t.eq('tp <destination>', pg_temp.sig(4, 'tp Bob'), 'teleport/destination');
  select t.eq('tp <targets> <destination>', pg_temp.sig(4, 'tp Bob Cy'), 'teleport/targets/destination');
  select t.eq('tp <location>', pg_temp.sig(4, 'tp 1 2 3'), 'teleport/location');
  select t.eq('tp <targets> <location> <rotation>', pg_temp.sig(4, 'tp Bob 1 2 3 4 5'), 'teleport/targets/location/rotation');
  select t.eq('/tell and /w are /msg', pg_temp.sig(4, 'tell Bob hi'), 'msg/targets/message');
  select t.eq('time set <time>', pg_temp.sig(4, 'time set 100'), 'time/set/time');
  select t.eq('time set <marker>: "5x" is not a time, so it is a marker (as vanilla found out)', pg_temp.sig(4, 'time set 5x'), 'time/set/timemarker');
  select t.eq('time set 1d = 24000 ticks', ((mc.cmd_parse(4, 'time set 1d')).args ->> 'time')::int, 24000);
  select t.eq('time set 1s = 20 ticks, 3t = 3', array[((mc.cmd_parse(4, 'time set 1s')).args ->> 'time')::int, ((mc.cmd_parse(4, 'time set 3t')).args ->> 'time')::int], array[20, 3]);
  select t.eq('a gamerule with its prefix', pg_temp.sig(4, 'gamerule minecraft:pvp true'), 'gamerule/minecraft:pvp/value');
  select t.eq('integer x z are centred, y is not (vec3)', (mc.cmd_parse(4, 'tp 1 2 3')).args -> 'location', '["1.5", "2", "3.5"]'::jsonb);
  select t.eq('relative and decimal coordinates are kept as typed', (mc.cmd_parse(4, 'tp ~ ~1.5 3.25')).args -> 'location', '["~", "~1.5", "3.25"]'::jsonb);
  select t.eq('a message keeps everything after the separator, even spaces', (mc.cmd_parse(4, 'say  a  b')).args #>> '{message,text}', ' a  b');
  select t.eq('no selectors below level 2: a message is plain text', (mc.cmd_parse(0, 'msg Bob @a hi')).args #>> '{message,parts}', '[]');
  select t.eq('selectors in a message are parsed where they stand', (mc.cmd_parse(4, 'say x @a[name=Bob] y')).args #> '{message,parts,0,start}', '2');
  select t.eq('...an unknown selector type in a message is just text', jsonb_array_length((mc.cmd_parse(4, 'say @x @ hello')).args #> '{message,parts}'), 0);
  select t.eq('...a malformed one is an error', (mc.cmd_parse(4, 'say @a[foo=1]')).ex_key, 'argument.entity.options.unknown');
  select t.eq('a long unquoted name (more than 16 characters) is not a name', (mc.cmd_parse(4, 'msg abcdefghijklmnopq x')).ex_key, 'argument.entity.invalid');
  select t.eq('a quoted name', (mc.cmd_parse(4, 'msg "Bob" x')).args #>> '{targets,name}', 'Bob');

  -- what dbcraft cannot parse is said so (literal text, key starts with !), never silently accepted
  select t.is_true('item components are not supported: said so', (mc.cmd_parse(4, 'give Bob stone[x=1]')).ex_key like '!%');
  select t.eq('local coordinates parse', (mc.cmd_parse(4, 'tp ^ ^1.5 ^-2')).args -> 'location', '["^", "^1.5", "^-2"]'::jsonb);
  select t.eq('...mixing local and world coordinates is an error', (mc.cmd_parse(4, 'tp ^ 1 2')).ex_key, 'command.unknown.argument');
  select t.eq('Mth.sin / Mth.cos are the table versions (0.5 at 30 degrees is not exact)', array[mc.mth_sin(1.5707964::real), mc.mth_cos(0::real)], array[1::real, 1::real]);
  select t.is_true('the selector options advancements, nbt, predicate, scores, x_rotation, y_rotation are not supported: said so', (mc.cmd_parse(4, 'msg @a[nbt={}] x')).ex_key like '!%');

  -- the dispatcher's search: a level only sees its own tree
  select t.eq('level 2 does not see /op (level 3), level 3 does', array[(mc.cmd_parse(2, 'op Bob')).ok, (mc.cmd_parse(3, 'op Bob')).ok], array[false, true]);
  select t.eq('level 3 does not see /stop (level 4), level 4 does', array[(mc.cmd_parse(3, 'stop')).ok, (mc.cmd_parse(4, 'stop')).ok], array[false, true]);
  select t.eq('level 1 sees what level 0 sees', array[(mc.cmd_parse(1, 'list')).ok, (mc.cmd_parse(1, 'gamemode creative')).ok], array[true, false]);
\else
  do $$ begin raise notice 'SKIPPED the command graph is not loaded (tools/load_command_tree.py needs the recording play_op4)'; end $$;
\endif
