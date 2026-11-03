-- Game module, part 6: chat, commands and their feedback.
-- Component shapes below were decoded from the real server's packets with tools/nbt_dump.py; those marked (verified) are reproduced byte for byte by
-- tests/game_verify.py.  Everything else follows the same shapes but could not be compared (marked "unverified").

------------------------------------------------------------------------------------------------ tables
-- Vanilla's chat_type registry as the configuration phase sends it: sorted by name.  chat=0 and say_command=4 are confirmed by captures; the
-- rest follow from the same sort order.  (The connection layer must send the registry in this order or update this table.)
create table if not exists mc.chat_type (name text primary key, id int not null unique);
insert into mc.chat_type values ('minecraft:chat', 0), ('minecraft:emote_command', 1), ('minecraft:msg_command_incoming', 2), ('minecraft:msg_command_outgoing', 3),
  ('minecraft:say_command', 4), ('minecraft:team_msg_command_incoming', 5), ('minecraft:team_msg_command_outgoing', 6) on conflict do nothing;
create or replace function mc.chat_type_id(n text) returns int language sql stable parallel safe as $$ select id from mc.chat_type where name = n $$;

create table if not exists mc.chat_log (
    id bigint generated always as identity primary key, at timestamptz not null default now(),
    kind text not null check (kind in ('chat', 'command', 'say')), sender uuid, sender_name text, message text not null);

-- Commands and the permission level that unlocks them (vanilla's levels; a player below the level gets "unknown command", as in vanilla, where the
-- command is simply absent from the player's command tree).
create table if not exists mc.command (name text primary key, level int not null check (level between 0 and 4), usage text);
-- Only commands that are implemented are listed (not yet: msg, me, help, kill, seed, and the rest of vanilla's ~90 commands).
insert into mc.command values
  ('list', 0, 'list'),
  ('say', 2, 'say <message>'), ('tp', 2, 'tp <destination> | <targets> <destination> | <x> <y> <z> | <targets> <x> <y> <z>'), ('teleport', 2, 'teleport <destination> | <targets> <destination> | <x> <y> <z> | <targets> <x> <y> <z>'), ('gamemode', 2, 'gamemode <mode> [player]'),
  ('give', 2, 'give <player> <item> [count]'), ('time', 2, 'time set|add <value>'), ('weather', 2, 'weather clear|rain|thunder'), ('difficulty', 2, 'difficulty <level>'),
  ('op', 3, 'op <player>'), ('deop', 3, 'deop <player>'), ('whitelist', 3, 'whitelist on|off|add|remove|list'), ('ban', 3, 'ban <player> [reason]'), ('pardon', 3, 'pardon <player>')
on conflict (name) do nothing;

------------------------------------------------------------------------------------------------ component helpers
-- A list<compound> must hold only compounds, so vanilla wraps plain arguments as {"": value} (seen in /tp and /give feedback).
create or replace function mc.tc_arg_str(v text) returns bytea language sql immutable parallel safe as $$ select proto.nbt_str('', v) $$;
create or replace function mc.tc_arg_int(v int) returns bytea language sql immutable parallel safe as $$ select proto.nbt_int('', v) $$;
-- red failure wrapper: {color: red, extra: [inner], text: ""}  (verified: "Unknown or incomplete command", "difficulty is already ...")
create or replace function mc.tc_failure(inner_fields bytea) returns bytea language sql immutable parallel safe as $$
  select proto.cat(array[proto.nbt_str('color', 'red'), proto.nbt_list_comp('extra', array[inner_fields]), proto.nbt_str('text', '')]) $$;
-- a plain text component sent as a root is a bare string tag (verified: /say content)
create or replace function mc.nbt_root_text(txt text) returns bytea language sql immutable parallel safe as $$ select '\x08'::bytea || proto.nbt_text(txt) $$;
-- "[Item]" component used by /give (verified): hover shows the item, name from the block or item translation key
create or replace function mc.tc_item(item text) returns bytea language sql stable parallel safe as $$
  select proto.cat(array[
    proto.nbt_list_comp('with', array[proto.cat(array[
        proto.nbt_list_comp('extra', array[mc.tc_translate((case when exists (select 1 from ref.block where name = item) then 'block.' else 'item.' end) || replace(item, ':', '.'))]),
        proto.nbt_str('text', '')])]),
    proto.nbt_str('color', 'white'),
    proto.nbt_comp('hover_event', proto.nbt_str('action', 'show_item'), proto.nbt_str('id', item)),
    proto.nbt_str('translate', 'chat.square_brackets')]) $$;

create or replace function mc.pkt_disguised_chat(content_text text, chat_type_id int, name_fields bytea) returns bytea language sql stable parallel safe as $$
  select mc.cb('disguised_chat', mc.nbt_root_text(content_text) || proto.varint(chat_type_id + 1) || proto.nbt_root(name_fields) || proto.bool(false)) $$;
create or replace function mc.pkt_game_event(event int, val real) returns bytea language sql stable parallel safe as $$ select mc.cb('game_event', proto.i8(event) || proto.f32(val)) $$;
-- abilities flags: 1 invulnerable, 2 flying, 4 may fly, 8 instant build; speeds 0.05 / 0.1 (verified)
create or replace function mc.pkt_player_abilities(flags int, fly_speed real default 0.05, walk_speed real default 0.1) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_abilities', proto.i8(flags) || proto.f32(fly_speed) || proto.f32(walk_speed)) $$;
create or replace function mc.pkt_change_difficulty(difficulty int, locked boolean default false) returns bytea language sql stable parallel safe as $$
  select mc.cb('change_difficulty', proto.i8(difficulty) || proto.bool(locked)) $$;
create or replace function mc.pkt_container_set_slot(state_id int, slot int, item text, cnt int) returns bytea language sql stable parallel safe as $$
  select mc.cb('container_set_slot', proto.varint(0) || proto.varint(state_id) || proto.i16(slot)
       || case when cnt > 0 then proto.varint(cnt) || proto.varint(mc.item_id(item)) || proto.varint(0) || proto.varint(0) else proto.varint(0) end) $$;
create or replace function mc.gamemode_abilities(gm int) returns int language sql immutable parallel safe as $$ select case gm when 1 then 13 when 3 then 7 else 0 end $$;

create or replace function mc.feedback(p_conn int, fields bytea) returns void language sql as $$
  insert into mc.play_out (conn_id, data) values (p_conn, mc.pkt_system_chat(proto.nbt_root(fields))) $$;
create or replace function mc.broadcast(fields bytea) returns void language sql as $$
  insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_system_chat(proto.nbt_root(fields)) from mc.player where conn_id is not null order by entity_id $$;

-- exception-safe String reader for hostile input: (NULL, NULL) when malformed
create or replace function proto.string_safe(b bytea, off int default 0, out val text, out nxt int) language plpgsql immutable parallel safe as $$
begin select r.val, r.nxt into val, nxt from proto.string_read(b, off) r; exception when others then val := null; nxt := null; end $$;

------------------------------------------------------------------------------------------------ commands
create or replace function mc.find_player(p_name text) returns mc.player language sql stable as $$
  select p from mc.player p where p.conn_id is not null and lower(p.name) = lower(p_name) limit 1 $$;

-- Code that moves a player other than by a movement packet (/tp) must make the shared "last told" position current at once: the tick's visibility step runs
-- in the same tick and adds newly visible viewers at that position.  Found with real clients: after "/tp" the add_entity carried the OLD position (70 blocks
-- away, in a chunk the viewer had not loaded) and the correcting teleport came a tick later; a real client keeps an entity added in an unloaded chunk hidden and
-- never moves it, so the teleported player stayed invisible.  Viewers that already see the player get the teleport now.
create or replace function mc.sync_entity_position(p_uuid uuid) returns void language plpgsql as $$
declare p mc.player;
begin
  select * into p from mc.player where uuid = p_uuid;
  if not found or p.entity_id is null then return; end if;
  -- Only a jump that vanilla's entity tracker sends as a TELEPORT (a delta that does not fit in a short, more than 8 blocks: the movement step's own test) is
  -- handled here.  A shorter /tp stays a relative move sent by the next movement step, exactly as before (tests/sql/36 pins those bytes, vanilla does the same),
  -- and the stale base is then at most 8 blocks from the real position, which a new viewer's loaded area still contains.
  if abs(mc.quant(p.x) - p.sent_qx) <= 32767 and abs(mc.quant(p.y) - p.sent_qy) <= 32767 and abs(mc.quant(p.z) - p.sent_qz) <= 32767 then return; end if;
  insert into mc.play_out (conn_id, data)
    select v.viewer_conn, mc.pkt_teleport_entity(p.entity_id, p.x, p.y, p.z, 0, 0, 0, p.yaw, p.pitch, p.on_ground) || mc.pkt_rotate_head(p.entity_id, p.yaw)
      from mc.visible v where v.target_eid = p.entity_id and v.viewer_conn <> p.conn_id order by v.viewer_conn;
  update mc.player set sent_qx = mc.quant(x), sent_qy = mc.quant(y), sent_qz = mc.quant(z), sent_yaw = yaw, sent_pitch = pitch where uuid = p_uuid;
end $$;

create or replace function mc.run_command(p_conn int, cmd text) returns void language plpgsql as $$
declare
  me mc.player; lvl int; tok text[]; verb text; need int; tgt mc.player; gm int; x float8; y float8; z float8; n int; give_item text; cur record; names text[]; bnames bytea[];
  tid int; state int; markers jsonb := '{"day":1000,"noon":6000,"night":13000,"midnight":18000}'; oplevel int; oldval text; dst mc.player;
begin
  select * into me from mc.player where conn_id = p_conn;
  if not found then return; end if;
  lvl := mc.permission_level(me.uuid);
  tok := regexp_split_to_array(btrim(cmd), '\s+'); verb := lower(tok[1]);
  select level into need from mc.command where name = verb;
  insert into mc.chat_log (kind, sender, sender_name, message) values ('command', me.uuid, me.name, cmd);
  if need is null or lvl < need then perform mc.unknown_command(p_conn, cmd); return; end if;

  if verb = 'list' then
    select array_agg(mc.tc_player(uuid, name) order by entity_id) into bnames from mc.player where conn_id is not null;
    -- (verified) {with:[count, max, {extra: [name, ", " (gray), name ...], text: ""}], translate: commands.list.players}
    perform mc.feedback(p_conn, mc.tc_translate('commands.list.players', array[
      mc.tc_arg_int(coalesce(array_length(bnames, 1), 0)), mc.tc_arg_int(mc.prop_int('max-players')),
      proto.cat(array[proto.nbt_list_comp('extra', (select array_agg(e order by o) from (
          select 2 * i - 1 as o, bnames[i] as e from generate_series(1, coalesce(array_length(bnames, 1), 0)) i
          union all select 2 * i, mc.tc_text(', ', 'gray') from generate_series(1, coalesce(array_length(bnames, 1), 0) - 1) i) q)), proto.nbt_str('text', '')])]));

  elsif verb = 'say' then
    if tok[2] is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.argument'))); return; end if;   -- unverified shape
    insert into mc.chat_log (kind, sender, sender_name, message) values ('say', me.uuid, me.name, btrim(substr(btrim(cmd), 4)));
    insert into mc.play_out (conn_id, data)       -- (verified) disguised_chat with the say_command chat type
      select conn_id, mc.pkt_disguised_chat(btrim(substr(btrim(cmd), 4)), mc.chat_type_id('minecraft:say_command'), mc.tc_player(me.uuid, me.name))
        from mc.player where conn_id is not null order by entity_id;

  elsif verb = 'time' then
    if lower(tok[2]) = 'set' and markers ? lower(tok[3]) then
      -- the next time the marker occurs.  (Vanilla answered /time set day at game time 5738 with clock total 49000 = 2 days + 1000; why it skipped a
      -- day is not understood, so the totals can differ from vanilla's, though the packet layout is identical.)
      update mc.game_state set day_time = day_time - day_time % 24000 + (markers ->> lower(tok[3]))::bigint
                                          + case when day_time % 24000 >= (markers ->> lower(tok[3]))::bigint then 24000 else 0 end;
      insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_set_time((select game_time from mc.game_state), array[0], array[(select day_time from mc.game_state)])
        from mc.player where conn_id is not null order by entity_id;
      perform mc.feedback(p_conn, mc.tc_translate_strs('commands.time.set.time_marker', array['minecraft:overworld', 'minecraft:' || lower(tok[3])]));   -- (verified for 'day')
    elsif lower(tok[2]) in ('set', 'add') and tok[3] ~ '^-?[0-9]+$' then
      update mc.game_state set day_time = case when lower(tok[2]) = 'set' then tok[3]::bigint else day_time + tok[3]::bigint end;
      insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_set_time((select game_time from mc.game_state), array[0], array[(select day_time from mc.game_state)])
        from mc.player where conn_id is not null order by entity_id;
      perform mc.feedback(p_conn, proto.cat(array[proto.nbt_list_comp('with', array[mc.tc_arg_int((select day_time from mc.game_state)::int)]),
                                                  proto.nbt_str('translate', case lower(tok[2]) when 'set' then 'commands.time.set' else 'commands.time.add' end)]));   -- unverified
    else perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.argument'))); end if;

  elsif verb = 'weather' then
    if lower(tok[2]) in ('clear', 'rain', 'thunder') then
      -- events only when the weather changes (the real server sent none for "weather clear" on a clear world)
      if (select raining <> (lower(tok[2]) <> 'clear') or thundering <> (lower(tok[2]) = 'thunder') from mc.game_state) then
        insert into mc.play_out (conn_id, data)       -- unverified: STOP_RAINING / START_RAINING, then the rain and thunder levels
          select conn_id, case when lower(tok[2]) = 'clear' then mc.pkt_game_event(2, 0) else mc.pkt_game_event(1, 0) end
                       || mc.pkt_game_event(7, case when lower(tok[2]) = 'clear' then 0 else 1 end) || mc.pkt_game_event(8, case when lower(tok[2]) = 'thunder' then 1 else 0 end)
            from mc.player where conn_id is not null order by entity_id;
      end if;
      update mc.game_state set raining = lower(tok[2]) <> 'clear', thundering = lower(tok[2]) = 'thunder';
      perform mc.feedback(p_conn, mc.tc_translate('commands.weather.set.' || lower(tok[2])));       -- (verified for 'clear')
    else perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.argument'))); end if;

  elsif verb = 'gamemode' then
    gm := case lower(tok[2]) when 'survival' then 0 when 'creative' then 1 when 'adventure' then 2 when 'spectator' then 3 end;
    tgt := case when tok[3] is null then me else mc.find_player(tok[3]) end;
    if gm is null or tgt.uuid is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate(case when gm is null then 'command.unknown.argument' else 'argument.entity.notfound.player' end))); return; end if;
    update mc.player set gamemode = gm where uuid = tgt.uuid;
    -- (verified order seen by the target: abilities, tab-list game mode to everyone, change-game-mode event, abilities, "Your game mode has been updated")
    insert into mc.play_out (conn_id, data) values (tgt.conn_id, mc.pkt_player_abilities(mc.gamemode_abilities(gm)));
    insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_player_info_gamemode(tgt.uuid, gm) from mc.player where conn_id is not null order by entity_id;
    insert into mc.play_out (conn_id, data) values (tgt.conn_id, mc.pkt_game_event(3, gm::real) || mc.pkt_player_abilities(mc.gamemode_abilities(gm)));
    if tgt.uuid <> me.uuid then
      perform mc.feedback(tgt.conn_id, mc.tc_translate('gameMode.changed', array[mc.tc_translate('gameMode.' || lower(tok[2]))]));
      perform mc.feedback(p_conn, mc.tc_translate('commands.gamemode.success.other', array[mc.tc_player(tgt.uuid, tgt.name), mc.tc_translate('gameMode.' || lower(tok[2]))]));
    else
      perform mc.feedback(p_conn, mc.tc_translate('commands.gamemode.success.self', array[mc.tc_translate('gameMode.' || lower(tok[2]))]));      -- unverified key
    end if;

  elsif verb in ('tp', 'teleport') then
    -- Vanilla's forms: tp <destination> | tp <targets> <destination> | tp <x> <y> <z> | tp <targets> <x> <y> <z>.  The first two were missing until a REAL client
    -- sent "/tp Name" (docs/REAL-CLIENT.md): the code only knew the last form.  Targets and destinations are player names (no selectors yet).
    if cardinality(tok) = 4 and tok[2] ~ '^~?-?[0-9]*(\.[0-9]+)?$' and tok[2] <> '' then       -- tp <x> <y> <z>: the sender is the target
      tok := array[tok[1], me.name, tok[2], tok[3], tok[4]];
    end if;
    if cardinality(tok) in (2, 3) then
      tgt := case when cardinality(tok) = 2 then me else mc.find_player(tok[2]) end;
      dst := mc.find_player(tok[cardinality(tok)]);
      if tgt.uuid is null or dst.uuid is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.entity.notfound.player'))); return; end if;
      tid := tgt.teleport_id + 1;
      -- the target takes the destination's position AND rotation (vanilla: teleportToEntity)
      update mc.player set x = dst.x, y = dst.y, z = dst.z, yaw = dst.yaw, pitch = dst.pitch, chunk_x = floor(dst.x / 16)::int, chunk_z = floor(dst.z / 16)::int,
                           vis_dirty = true, teleport_id = tid, awaiting_teleport = tid
       where uuid = tgt.uuid;
      insert into mc.play_out (conn_id, data) values (tgt.conn_id, mc.pkt_player_position(tid, dst.x, dst.y, dst.z, 0, 0, 0, dst.yaw, dst.pitch, 0));   -- all absolute (flags 0)
      perform mc.sync_entity_position(tgt.uuid);
      perform mc.feedback(p_conn, mc.tc_translate('commands.teleport.success.entity.single', array[mc.tc_player(tgt.uuid, tgt.name), mc.tc_player(dst.uuid, dst.name)]));
      return;
    end if;
    tgt := mc.find_player(tok[2]);
    if tgt.uuid is null or tok[3] is null or tok[4] is null or tok[5] is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.entity.notfound.player'))); return; end if;
    begin
      x := case when tok[3] like '~%' then tgt.x + coalesce(nullif(substr(tok[3], 2), ''), '0')::float8 else tok[3]::float8 end;
      y := case when tok[4] like '~%' then tgt.y + coalesce(nullif(substr(tok[4], 2), ''), '0')::float8 else tok[4]::float8 end;
      z := case when tok[5] like '~%' then tgt.z + coalesce(nullif(substr(tok[5], 2), ''), '0')::float8 else tok[5]::float8 end;
    exception when others then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.argument'))); return; end;
    -- vanilla centres integer coordinates on the block (10 -> 10.5), as the captured feedback "10.500000" shows
    x := case when tok[3] ~ '^-?[0-9]+$' then floor(x) + 0.5 else x end; z := case when tok[5] ~ '^-?[0-9]+$' then floor(z) + 0.5 else z end;
    tid := tgt.teleport_id + 1;
    update mc.player set x = tp.x, y = tp.y, z = tp.z, chunk_x = floor(tp.x / 16)::int, chunk_z = floor(tp.z / 16)::int, vis_dirty = true,
                         teleport_id = tid, awaiting_teleport = tid
      from (select x, y, z) tp where uuid = tgt.uuid;
    -- (verified) player_position with the rotation kept: relative flags 0x18 (yaw and pitch relative) and zero rotation values
    insert into mc.play_out (conn_id, data) values (tgt.conn_id, mc.pkt_player_position(tid, x, y, z, 0, 0, 0, 0, 0, 24));
    perform mc.sync_entity_position(tgt.uuid);
    perform mc.feedback(p_conn, mc.tc_translate('commands.teleport.success.location.single',
      array[mc.tc_player(tgt.uuid, tgt.name), mc.tc_arg_str(to_char(x, 'FM999999999990.000000')), mc.tc_arg_str(to_char(y, 'FM999999999990.000000')), mc.tc_arg_str(to_char(z, 'FM999999999990.000000'))]));

  elsif verb = 'give' then
    tgt := mc.find_player(tok[2]);
    give_item := case when tok[3] like '%:%' then tok[3] else 'minecraft:' || tok[3] end;
    if tgt.uuid is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.entity.notfound.player'))); return; end if;
    if mc.item_id(give_item) is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.item.id.invalid', array[mc.tc_arg_str(give_item)]))); return; end if;
    n := coalesce(nullif(tok[4], '')::int, 1);
    if n < 1 then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.argument'))); return; end if;
    -- slots are filled like vanilla's Inventory.add: merge into an existing stack of the same item (max 64 here; per-item stack limits are not in the data),
    -- else the first empty hotbar slot, then the main inventory
    declare left_n int := n; add_n int; sl int; st int;
    begin
      for sl in select s from (select generate_series(36, 44) s union all select generate_series(9, 35)) q order by (s >= 36) desc, s loop
        exit when left_n <= 0;
        select count into st from mc.inventory_slot where player = tgt.uuid and slot = sl and mc.inventory_slot.item = give_item and count < 64;
        if st is not null then add_n := least(64 - st, left_n);
        elsif not exists (select 1 from mc.inventory_slot where player = tgt.uuid and slot = sl) then st := 0; add_n := least(64, left_n);
        else continue; end if;
        perform mc.set_slot(tgt.uuid, sl, give_item, st + add_n);
        left_n := left_n - add_n;
        update mc.player set inv_state = inv_state + 1 where uuid = tgt.uuid returning inv_state into state;
        insert into mc.play_out (conn_id, data) values (tgt.conn_id, mc.pkt_container_set_slot(state, sl, give_item, st + add_n));   -- (verified: container 0, state id 2, slot 36, stack of 8)
      end loop;
    end;
    perform mc.feedback(p_conn, mc.tc_translate('commands.give.success.single', array[mc.tc_arg_int(n), mc.tc_item(give_item), mc.tc_player(tgt.uuid, tgt.name)]));

  elsif verb = 'difficulty' then
    n := case lower(tok[2]) when 'peaceful' then 0 when 'easy' then 1 when 'normal' then 2 when 'hard' then 3 end;
    if n is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.argument'))); return; end if;
    oldval := mc.prop('difficulty');
    if oldval = lower(tok[2]) then   -- (verified) failure: already that difficulty
      perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('commands.difficulty.failure', array[mc.tc_translate('options.difficulty.' || lower(tok[2]))])));
    else
      update mc.server_property set value = lower(tok[2]) where key = 'difficulty';
      insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_change_difficulty(n, false) from mc.player where conn_id is not null order by entity_id;
      perform mc.feedback(p_conn, mc.tc_translate('commands.difficulty.success', array[mc.tc_translate('options.difficulty.' || lower(tok[2]))]));   -- unverified key
    end if;

  elsif verb = 'op' or verb = 'deop' then
    select * into tgt from mc.player where lower(name) = lower(tok[2]) limit 1;
    if tgt.uuid is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.entity.notfound.player'))); return; end if;
    oplevel := mc.prop_int('op-permission-level');
    if verb = 'op' then insert into mc.op (uuid, name, level) values (tgt.uuid, tgt.name, oplevel) on conflict (uuid) do nothing;
    else delete from mc.op where uuid = tgt.uuid; end if;
    perform mc.feedback(p_conn, mc.tc_translate_strs('commands.' || verb || '.success', array[tgt.name]));      -- (verified for op: {with: list<string>[name], translate})

  elsif verb = 'whitelist' then
    if lower(tok[2]) = 'list' then
      select array_agg(name order by name) into names from mc.whitelist;
      if names is null then perform mc.feedback(p_conn, mc.tc_translate('commands.whitelist.none'));          -- (verified)
      else perform mc.feedback(p_conn, mc.tc_translate('commands.whitelist.list', array[mc.tc_arg_int(array_length(names, 1)), mc.tc_arg_str(array_to_string(names, ', '))])); end if;   -- unverified
    elsif lower(tok[2]) in ('add', 'remove') then
      select * into tgt from mc.player where lower(name) = lower(tok[3]) limit 1;
      if tgt.uuid is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.entity.notfound.player'))); return; end if;
      if lower(tok[2]) = 'add' then insert into mc.whitelist values (tgt.uuid, tgt.name) on conflict do nothing; else delete from mc.whitelist where uuid = tgt.uuid; end if;
      perform mc.feedback(p_conn, mc.tc_translate('commands.whitelist.' || lower(tok[2]) || '.success', array[mc.tc_player(tgt.uuid, tgt.name)]));     -- unverified keys
    elsif lower(tok[2]) in ('on', 'off') then
      update mc.server_property set value = (lower(tok[2]) = 'on')::text where key = 'white-list';
      perform mc.feedback(p_conn, mc.tc_translate(case lower(tok[2]) when 'on' then 'commands.whitelist.enabled' else 'commands.whitelist.disabled' end));  -- unverified
    else perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.argument'))); end if;

  elsif verb = 'ban' then
    select * into tgt from mc.player where lower(name) = lower(tok[2]) limit 1;
    if tgt.uuid is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.entity.notfound.player'))); return; end if;
    insert into mc.ban (kind, uuid, name, reason, source) values ('player', tgt.uuid, tgt.name, coalesce(nullif(btrim(substr(btrim(cmd), length(tok[1]) + length(tok[2]) + 2)), ''), 'Banned by an operator.'), me.name)
      on conflict (uuid) where kind = 'player' do nothing;
    if tgt.conn_id is not null then perform mc.kick(tgt.conn_id, 'multiplayer.disconnect.banned.reason', array[(select reason from mc.ban where kind = 'player' and uuid = tgt.uuid)]); end if;
    perform mc.feedback(p_conn, mc.tc_translate('commands.ban.success', array[mc.tc_player(tgt.uuid, tgt.name), mc.tc_arg_str((select reason from mc.ban where kind = 'player' and uuid = tgt.uuid))]));   -- unverified

  elsif verb = 'pardon' then
    select * into tgt from mc.player where lower(name) = lower(tok[2]) limit 1;
    delete from mc.ban where kind = 'player' and uuid = tgt.uuid;
    perform mc.feedback(p_conn, mc.tc_translate_strs('commands.pardon.success', array[coalesce(tgt.name, tok[2])]));      -- unverified

  elsif verb = 'kill' then
    perform mc.cmd_kill(p_conn, tok);      -- sql/836 (survival)
  else
    perform mc.unknown_command(p_conn, cmd);
  end if;
end $$;

-- Two messages, as the real server sends them (verified for a one-word command): "Unknown or incomplete command, see below for error", then a
-- clickable context line showing the input with <--[HERE].  For multi-word input vanilla cuts the context at the failing position; here the first word is shown.
create or replace function mc.unknown_command(p_conn int, cmd text) returns void language plpgsql as $$
begin
  perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('command.unknown.command')));
  perform mc.feedback(p_conn, proto.cat(array[
    proto.nbt_str('color', 'red'),
    proto.nbt_list_comp('extra', array[proto.cat(array[
      proto.nbt_comp('click_event', proto.nbt_str('action', 'suggest_command'), proto.nbt_str('command', '/' || btrim(cmd))),
      proto.nbt_str('color', 'gray'),
      proto.nbt_list_comp('extra', array[
        proto.cat(array[proto.nbt_str('color', 'red'), proto.nbt_byte('underlined', 1), proto.nbt_str('text', (regexp_split_to_array(btrim(cmd), '\s+'))[1])]),
        proto.cat(array[proto.nbt_str('color', 'red'), proto.nbt_byte('italic', 1), proto.nbt_str('translate', 'command.context.here')])]),
      proto.nbt_str('text', '')])]),
    proto.nbt_str('text', '')]));
end $$;
