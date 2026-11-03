-- Commands, part 3: what the command implementations share: selector resolution, feedback (to the executor and to the operators), error reports,
-- game rules, message components.

------------------------------------------------------------------------------------------------ game rules
-- The server's game rules.  Names, types and defaults are those of the real 26.3 server (every one was read back with `/gamerule <rule>` from a vanilla server
-- and compared with this table in tests/e2e/compare_commands.py).  Their ranges come from the command graph (the argument's min/max).  Only the commands
-- read and write them here; a module that gives a rule a meaning (keep_inventory, pvp, ...) reads mc.gamerule_get / mc.gamerule_bool.
create table if not exists mc.gamerule (name text primary key, vtype text not null check (vtype in ('bool', 'int')), default_value text not null, value text not null);
insert into mc.gamerule (name, vtype, default_value, value) select n, t, d, d from (values
  ('advance_time', 'bool', 'true'),
  ('advance_weather', 'bool', 'true'),
  ('allow_entering_nether_using_portals', 'bool', 'true'),
  ('block_drops', 'bool', 'true'),
  ('block_explosion_drop_decay', 'bool', 'true'),
  ('command_block_output', 'bool', 'true'),
  ('command_blocks_work', 'bool', 'true'),
  ('drowning_damage', 'bool', 'true'),
  ('elytra_movement_check', 'bool', 'true'),
  ('ender_pearls_vanish_on_death', 'bool', 'true'),
  ('entity_drops', 'bool', 'true'),
  ('fall_damage', 'bool', 'true'),
  ('fire_damage', 'bool', 'true'),
  ('fire_spread_radius_around_player', 'int', '128'),
  ('forgive_dead_players', 'bool', 'true'),
  ('freeze_damage', 'bool', 'true'),
  ('global_sound_events', 'bool', 'true'),
  ('immediate_respawn', 'bool', 'false'),
  ('keep_inventory', 'bool', 'false'),
  ('lava_source_conversion', 'bool', 'false'),
  ('limited_crafting', 'bool', 'false'),
  ('locator_bar', 'bool', 'true'),
  ('log_admin_commands', 'bool', 'true'),
  ('max_block_modifications', 'int', '32768'),
  ('max_command_forks', 'int', '65536'),
  ('max_command_sequence_length', 'int', '65536'),
  ('max_entity_cramming', 'int', '24'),
  ('max_snow_accumulation_height', 'int', '1'),
  ('mob_drops', 'bool', 'true'),
  ('mob_explosion_drop_decay', 'bool', 'true'),
  ('mob_griefing', 'bool', 'true'),
  ('natural_health_regeneration', 'bool', 'true'),
  ('player_movement_check', 'bool', 'true'),
  ('players_nether_portal_creative_delay', 'int', '0'),
  ('players_nether_portal_default_delay', 'int', '80'),
  ('players_sleeping_percentage', 'int', '100'),
  ('projectiles_can_break_blocks', 'bool', 'true'),
  ('pvp', 'bool', 'true'),
  ('raids', 'bool', 'true'),
  ('random_tick_speed', 'int', '3'),
  ('reduced_debug_info', 'bool', 'false'),
  ('respawn_radius', 'int', '10'),
  ('send_command_feedback', 'bool', 'true'),
  ('show_advancement_messages', 'bool', 'true'),
  ('show_death_messages', 'bool', 'true'),
  ('spawn_mobs', 'bool', 'true'),
  ('spawn_monsters', 'bool', 'true'),
  ('spawn_patrols', 'bool', 'true'),
  ('spawn_phantoms', 'bool', 'true'),
  ('spawn_wandering_traders', 'bool', 'true'),
  ('spawn_wardens', 'bool', 'true'),
  ('spawner_blocks_work', 'bool', 'true'),
  ('spectators_generate_chunks', 'bool', 'true'),
  ('spread_vines', 'bool', 'true'),
  ('tnt_explodes', 'bool', 'true'),
  ('tnt_explosion_drop_decay', 'bool', 'false'),
  ('universal_anger', 'bool', 'false'),
  ('water_source_conversion', 'bool', 'true')
) v(n, t, d) on conflict do nothing;
create or replace function mc.gamerule_get(p_name text) returns text language sql stable as $$ select value from mc.gamerule where name = p_name $$;
create or replace function mc.gamerule_bool(p_name text) returns boolean language sql stable as $$ select coalesce((select value = 'true' from mc.gamerule where name = p_name), true) $$;

------------------------------------------------------------------------------------------------ small component helpers
create or replace function proto.nbt_list_int(p_name text, p_items int[]) returns bytea language sql immutable parallel safe as $$
  select '\x09'::bytea || proto.nbt_text(p_name) || '\x03'::bytea || proto.i32(coalesce(array_length(p_items, 1), 0))
         || coalesce((select string_agg(proto.i32(x), '\x'::bytea order by o) from unnest(p_items) with ordinality t(x, o)), '\x'::bytea) $$;

-- {with:[...], translate:key} from a JSON argument list: all strings = list<string>, all numbers = list<int> (vanilla's compact forms), none = no list
create or replace function mc.tc_translate_json(p_key text, p_args jsonb) returns bytea language sql immutable as $$
  select case
    when p_args is null or jsonb_array_length(p_args) = 0 then proto.nbt_str('translate', p_key)
    when not exists (select 1 from jsonb_array_elements(p_args) e where jsonb_typeof(e) <> 'string')
      then proto.nbt_list_str('with', array(select jsonb_array_elements_text(p_args))) || proto.nbt_str('translate', p_key)
    else proto.nbt_list_int('with', array(select (jsonb_array_elements_text(p_args))::numeric::int)) || proto.nbt_str('translate', p_key) end $$;

-- the failure wrapper (verified): {color: red, extra: [inner], text: ""}
create or replace function mc.cmd_fail(p_me mc.player, p_inner bytea) returns void language sql as $$
  insert into mc.play_out (conn_id, data) values (p_me.conn_id, mc.pkt_system_chat(proto.nbt_root(mc.tc_failure(p_inner)))) $$;

-- the line vanilla prints under a syntax error: the input up to the cursor (at most 10 characters, "..." before them when cut), the rest underlined in red,
-- then <--[HERE]  (Commands.performCommand; verified byte for byte against the real server)
create or replace function mc.cmd_context_fields(p_input text, p_cursor int) returns bytea language plpgsql immutable as $$
declare i int := least(length(p_input), greatest(p_cursor, 0)); from_ int := greatest(0, i - 10); items bytea[] := '{}';
begin
  if i > 10 then items := items || proto.nbt_str('', '...'); end if;
  if i > from_ then items := items || proto.nbt_str('', substr(p_input, from_ + 1, i - from_)); end if;
  if i < length(p_input) then
    items := items || proto.cat(array[proto.nbt_str('color', 'red'), proto.nbt_byte('underlined', 1), proto.nbt_str('text', substr(p_input, i + 1))]);
  end if;
  items := items || proto.cat(array[proto.nbt_str('color', 'red'), proto.nbt_byte('italic', 1), proto.nbt_str('translate', 'command.context.here')]);
  return proto.cat(array[
    proto.nbt_comp('click_event', proto.nbt_str('action', 'suggest_command'), proto.nbt_str('command', '/' || p_input)),
    proto.nbt_str('color', 'gray'), proto.nbt_list_comp('extra', items), proto.nbt_str('text', '')]);
end $$;

-- A command that did not parse: the error as a red message, then the context line.  p_key starting with '!' is literal text (a dbcraft limitation, said so).
create or replace function mc.cmd_report_error(p_me mc.player, p_input text, p_key text, p_args jsonb, p_cursor int) returns void language plpgsql as $$
begin
  perform mc.cmd_fail(p_me, case when left(p_key, 1) = '!' then proto.nbt_str('text', substr(p_key, 2)) else mc.tc_translate_json(p_key, p_args) end);
  perform mc.cmd_fail(p_me, mc.cmd_context_fields(p_input, p_cursor));
end $$;

-- compatibility: the old entry point (one line: the unknown-command pair for the whole input)
create or replace function mc.unknown_command(p_conn int, cmd text) returns void language plpgsql as $$
declare me mc.player;
begin
  select * into me from mc.player where conn_id = p_conn;
  if found then perform mc.cmd_report_error(me, cmd, 'command.unknown.command', null, 0); end if;
end $$;

------------------------------------------------------------------------------------------------ feedback
-- CommandSourceStack.sendSuccess(message, broadcastToAdmins): the executor gets the message; every OTHER operator gets it wrapped in chat.type.admin
-- (gray, italic) - both only while the game rule send_command_feedback is on (verified: with it off, even `/gamerule send_command_feedback true` answers
-- nothing until it is on again).  p_comp = the FIELDS of the message component.
create or replace function mc.cmd_success(p_me mc.player, p_comp bytea, p_admins boolean default true) returns void language plpgsql as $$
begin
  if not mc.gamerule_bool('send_command_feedback') then return; end if;
  insert into mc.play_out (conn_id, data) values (p_me.conn_id, mc.pkt_system_chat(proto.nbt_root(p_comp)));
  if p_admins then
    insert into mc.play_out (conn_id, data)
      select o.conn_id, mc.pkt_system_chat(proto.nbt_root(proto.cat(array[
               proto.nbt_list_comp('with', array[mc.tc_player(p_me.uuid, p_me.name), p_comp]), proto.nbt_str('color', 'gray'), proto.nbt_byte('italic', 1),
               proto.nbt_str('translate', 'chat.type.admin')])))
        from mc.player o where o.conn_id is not null and o.uuid <> p_me.uuid and exists (select 1 from mc.op where uuid = o.uuid) order by o.entity_id;
  end if;
end $$;
-- a plain string as a whole message (usage lines of /help): the root tag is a string
create or replace function mc.cmd_success_text(p_me mc.player, p_text text) returns void language sql as $$
  insert into mc.play_out (conn_id, data) values (p_me.conn_id, mc.pkt_system_chat(mc.nbt_root_text(p_text))) $$;

------------------------------------------------------------------------------------------------ selectors, resolved (EntitySelector.findPlayers / findEntities)
-- sel: the JSON mc.sel_parse made.  Only players exist as selectable entities here (mobs and items of the entity prototype are not selectable), so @e
-- means "every player" and a type other than minecraft:player selects nothing.  The origin of distance and sorting is the executor, or the x y z of the selector.
create or replace function mc.sel_players(p_sel jsonb, p_me mc.player) returns setof mc.player language plpgsql stable as $$
declare kind text := p_sel ->> 'kind'; lim int := (p_sel ->> 'limit')::int; srt text := coalesce(p_sel ->> 'sort', 'arbitrary');
  ox float8 := coalesce((p_sel ->> 'x')::float8, p_me.x); oy float8 := coalesce((p_sel ->> 'y')::float8, p_me.y); oz float8 := coalesce((p_sel ->> 'z')::float8, p_me.z);
begin
  if kind = 'name' then
    return query select p.* from mc.player p where p.conn_id is not null and lower(p.name) = lower(p_sel ->> 'name') limit 1; return;
  elsif kind = 'uuid' then
    return query select p.* from mc.player p where p.conn_id is not null and p.uuid = (p_sel ->> 'uuid')::uuid limit 1; return;
  end if;
  return query
    select p.* from (
      select p.*, row_number() over (order by case srt when 'nearest' then (p.x - ox) ^ 2 + (p.y - oy) ^ 2 + (p.z - oz) ^ 2
                                                       when 'furthest' then -((p.x - ox) ^ 2 + (p.y - oy) ^ 2 + (p.z - oz) ^ 2) end,
                                      case srt when 'random' then random() end, p.entity_id) as rn
        from mc.player p
       where p.conn_id is not null
         and (kind <> 's' or p.uuid = p_me.uuid)
         and (p_sel ->> 'name_eq' is null or p.name = p_sel ->> 'name_eq')
         and not (p.name = any (array(select jsonb_array_elements_text(coalesce(p_sel -> 'name_ne', '[]')))))
         and (p_sel -> 'dist' is null
              or (((p_sel -> 'dist' ->> 0) is null or (p.x - ox) ^ 2 + (p.y - oy) ^ 2 + (p.z - oz) ^ 2 >= ((p_sel -> 'dist' ->> 0)::float8) ^ 2)
              and ((p_sel -> 'dist' ->> 1) is null or (p.x - ox) ^ 2 + (p.y - oy) ^ 2 + (p.z - oz) ^ 2 <= ((p_sel -> 'dist' ->> 1)::float8) ^ 2)))
         and (p_sel ->> 'gm_eq' is null or p.gamemode = (p_sel ->> 'gm_eq')::int)
         and not (p.gamemode = any (array(select jsonb_array_elements_text(coalesce(p_sel -> 'gm_ne', '[]'))::int)))
         and (p_sel ->> 'type_eq' is null or p_sel ->> 'type_eq' = 'minecraft:player')
         and not ('minecraft:player' = any (array(select jsonb_array_elements_text(coalesce(p_sel -> 'type_ne', '[]')))))
         and (p_sel -> 'level' is null
              or (((p_sel -> 'level' ->> 0) is null or p.xp_level >= ((p_sel -> 'level' ->> 0)::float8))
              and ((p_sel -> 'level' ->> 1) is null or p.xp_level <= ((p_sel -> 'level' ->> 1)::float8))))
    ) p where lim is null or p.rn <= lim order by p.rn;
end $$;

-- findSingleEntity-style helpers: the players a selector argument names, in order; `not found` is the caller's error
create or replace function mc.sel_array(p_sel jsonb, p_me mc.player) returns mc.player[] language sql stable as $$
  select array(select s from mc.sel_players(p_sel, p_me) s) $$;

------------------------------------------------------------------------------------------------ message components (MessageArgument.resolveComponent)
-- The names a selector matched, as one component: a single name is the name itself, several are an empty parent with the names between gray ", "
create or replace function mc.sel_names_fields(p_players mc.player[]) returns bytea language sql stable as $$
  select case cardinality(p_players)
    when 0 then proto.nbt_str('', '')
    when 1 then mc.tc_player(p_players[1].uuid, p_players[1].name)
    else proto.cat(array[proto.nbt_list_comp('extra', (select array_agg(e order by o) from (
           select 2 * i - 1 as o, mc.tc_player(p_players[i].uuid, p_players[i].name) as e from generate_series(1, cardinality(p_players)) i
           union all select 2 * i, mc.tc_text(', ', 'gray') from generate_series(1, cardinality(p_players) - 1) i) q)), proto.nbt_str('text', '')]) end $$;

-- the root component of a message argument: plain text is a bare string; with selectors an empty parent holding the text pieces and the resolved names
create or replace function mc.msg_component_root(p_me mc.player, p_msg jsonb) returns bytea language plpgsql stable as $$
declare txt text := p_msg ->> 'text'; part jsonb; items bytea[] := '{}'; last_end int := 0;
begin
  if jsonb_array_length(coalesce(p_msg -> 'parts', '[]')) = 0 then return mc.nbt_root_text(txt); end if;
  for part in select * from jsonb_array_elements(p_msg -> 'parts') loop
    if (part ->> 'start')::int > last_end then items := items || proto.nbt_str('', substr(txt, last_end + 1, (part ->> 'start')::int - last_end)); end if;
    items := items || mc.sel_names_fields(mc.sel_array(part -> 'sel', p_me));
    last_end := (part ->> 'end')::int;
  end loop;
  if last_end < length(txt) then items := items || proto.nbt_str('', substr(txt, last_end + 1)); end if;
  return proto.nbt_root(proto.nbt_list_comp('extra', items), proto.nbt_str('text', ''));
end $$;

-- disguised_chat with the message as a ready NBT root and an optional target name (the "You whisper to" form of /msg)
create or replace function mc.pkt_disguised_chat_root(p_content_root bytea, p_chat_type int, p_name_fields bytea, p_target_fields bytea default null) returns bytea language sql stable as $$
  select mc.cb('disguised_chat', p_content_root || proto.varint(p_chat_type + 1) || proto.nbt_root(p_name_fields)
       || case when p_target_fields is null then proto.bool(false) else proto.bool(true) || proto.nbt_root(p_target_fields) end) $$;
