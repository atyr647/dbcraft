-- Commands, part 4: the dispatcher and the commands that existed before the graph (list say time weather gamemode tp give difficulty op deop whitelist ban pardon),
-- now driven by the parse of sql/811.
--
-- mc.cmd_execute(conn, text): parse for the player's permission level (a command that is not in the player's graph is unknown, a syntax error is reported with
-- vanilla's text and context line), then call mc.cmd_run_<command>(player, level, input, signature, arguments).  The signature is the path of the parse
-- (`gamemode/gamemode/target`; an alias such as /tp counts as the command it redirects to, `teleport`).  A command that is in the graph but has no
-- mc.cmd_run_<name> function is answered with a plain red "not implemented" line - it is never silently ignored.

create or replace function mc.cmd_execute(p_conn int, cmd text) returns void language plpgsql as $$
declare me mc.player; lvl int; res mc.cmd_res; sig text; root text; fn regprocedure;
begin
  select * into me from mc.player where conn_id = p_conn;
  if not found then return; end if;
  lvl := mc.permission_level(me.uuid);
  insert into mc.chat_log (kind, sender, sender_name, message) values ('command', me.uuid, me.name, cmd);
  -- a command of the player's graph that has no implementation here is said so before anything of its syntax is parsed (its argument types may be unsupported)
  select coalesce(t.name, n.name) into root from mc.cmd_child c join mc.cmd_node n on n.id = c.child left join mc.cmd_node t on t.id = n.redirect
   where c.parent = 0 and n.kind = 1 and n.min_level <= lvl and n.name = (regexp_match(cmd, '^[^ ]*'))[1];
  if root is not null and to_regprocedure('mc.cmd_run_' || replace(root, '-', '_') || '(mc.player,int,text,text,jsonb)') is null then
    perform mc.cmd_fail(me, proto.nbt_str('text', '/' || root || ' is not implemented in dbcraft'));
    return;
  end if;
  res := mc.cmd_parse(lvl, cmd);
  if not res.ok then perform mc.cmd_report_error(me, cmd, res.ex_key, res.ex_args, res.ex_cursor); return; end if;
  select string_agg(coalesce(t.name, n.name), '/' order by u.o) into sig
    from unnest(res.path) with ordinality u(id, o) join mc.cmd_node n on n.id = u.id left join mc.cmd_node t on t.id = n.redirect;
  root := split_part(sig, '/', 1);
  fn := to_regprocedure('mc.cmd_run_' || replace(root, '-', '_') || '(mc.player,int,text,text,jsonb)');
  if fn is null then
    perform mc.cmd_fail(me, proto.nbt_str('text', '/' || root || ' is not implemented in dbcraft'));
    return;
  end if;
  begin
    execute format('select mc.cmd_run_%s($1, $2, $3, $4, $5)', replace(root, '-', '_')) using me, lvl, cmd, sig, res.args;
  exception when others then
    raise warning 'mc.cmd_execute: "%" failed: % (%)', cmd, sqlerrm, sqlstate;
    perform mc.cmd_fail(me, mc.tc_translate('command.failed'));
  end;
end $$;

------------------------------------------------------------------------------------------------ helpers used by the commands
create or replace function mc.pkt_entity_event(p_entity_id int, p_event int) returns bytea language sql stable parallel safe as $$
  select mc.cb('entity_event', proto.i32(p_entity_id) || proto.i8(p_event)) $$;

-- the executor's player row, fresh (handlers get the row as it was when the command started)
create or replace function mc.cmd_me(p_uuid uuid) returns mc.player language sql stable as $$ select p from mc.player p where p.uuid = p_uuid $$;

-- A selector argument as the players it names, or the vanilla failure (no players found) and NULL
create or replace function mc.cmd_players(p_me mc.player, p_sel jsonb, p_entities boolean default false) returns mc.player[] language plpgsql as $$
declare r mc.player[] := mc.sel_array(p_sel, p_me);
begin
  if cardinality(r) = 0 then
    perform mc.cmd_fail(p_me, mc.tc_translate(case when p_entities then 'argument.entity.notfound.entity' else 'argument.entity.notfound.player' end));
    return null;
  end if;
  return r;
end $$;

-- A game-profile argument (op, deop, whitelist, ban, pardon): online players by name or selector, else a player the server has seen
create or replace function mc.cmd_profiles(p_me mc.player, p_sel jsonb) returns mc.player[] language plpgsql as $$
declare r mc.player[];
begin
  if p_sel ->> 'kind' = 'profile' then
    select array(select p from mc.player p where lower(p.name) = lower(p_sel ->> 'name') order by (p.conn_id is not null) desc limit 1) into r;
    if cardinality(r) = 0 then perform mc.cmd_fail(p_me, mc.tc_translate('argument.player.unknown')); return null; end if;
    return r;
  end if;
  return mc.cmd_players(p_me, p_sel);
end $$;

------------------------------------------------------------------------------------------------ /list
create or replace function mc.cmd_run_list(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare ps mc.player[]; comps bytea[];
begin
  select array_agg(p order by p.entity_id) into ps from mc.player p where p.conn_id is not null;
  select array_agg(case when sig = 'list/uuids' then mc.tc_translate_strs('commands.list.nameAndId', array[ps[i].name, ps[i].uuid::text]) else mc.tc_player(ps[i].uuid, ps[i].name) end order by i)
    into comps from generate_series(1, coalesce(cardinality(ps), 0)) i;
  -- (verified) {with:[count, max, {extra: [name, ", " (gray), name ...], text: ""}], translate: commands.list.players}
  perform mc.cmd_success(me, mc.tc_translate('commands.list.players', array[
      mc.tc_arg_int(coalesce(cardinality(comps), 0)), mc.tc_arg_int(mc.prop_int('max-players')),
      proto.cat(array[proto.nbt_list_comp('extra', (select array_agg(e order by o) from (
          select 2 * i - 1 as o, comps[i] as e from generate_series(1, coalesce(cardinality(comps), 0)) i
          union all select 2 * i, mc.tc_text(', ', 'gray') from generate_series(1, coalesce(cardinality(comps), 0) - 1) i) q)), proto.nbt_str('text', '')])]), false);
end $$;

------------------------------------------------------------------------------------------------ /time
create or replace function mc.cmd_run_time(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare v bigint; marker text; day bigint; cur bigint; markers jsonb := '{"minecraft:day":1000,"minecraft:noon":6000,"minecraft:night":13000,"minecraft:midnight":18000}';
begin
  if sig = 'time/query/gametime' then
    perform mc.cmd_success(me, proto.cat(array[proto.nbt_list_long('with', array[(select game_time from mc.game_state)]), proto.nbt_str('translate', 'commands.time.query.gametime')]), false);
    return;
  elsif sig = 'time/query/time' then
    perform mc.cmd_success(me, mc.tc_translate('commands.time.query.absolute', array[mc.tc_arg_str('minecraft:overworld'), mc.tc_arg_long((select day_time from mc.game_state))]), false);   -- (verified: the ticks are a long)
    return;
  elsif sig = 'time/set/timemarker' then
    marker := args ->> 'timemarker';
    if not markers ? marker then
      perform mc.cmd_fail(me, mc.tc_translate_strs('commands.time.no_time_marker_found', array[marker, 'minecraft:overworld'])); return;
    end if;
    day := (markers ->> marker)::bigint; select day_time into cur from mc.game_state;
    -- the next time the marker occurs (verified: /time set day, noon, midnight, night answered with the next occurrence after the clock's total)
    update mc.game_state set day_time = cur - cur % 24000 + day + case when cur % 24000 >= day then 24000 else 0 end;
  elsif sig in ('time/set/time', 'time/add/time') then
    v := (args ->> 'time')::bigint;
    update mc.game_state set day_time = case when sig = 'time/set/time' then v else day_time + v end;
  else
    perform mc.cmd_fail(me, proto.nbt_str('text', '/' || replace(sig, '/', ' ') || ' is not implemented in dbcraft')); return;
  end if;
  insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_set_time((select game_time from mc.game_state), array[0], array[(select day_time from mc.game_state)])
    from mc.player where conn_id is not null order by entity_id;
  if sig = 'time/set/timemarker' then
    perform mc.cmd_success(me, mc.tc_translate_strs('commands.time.set.time_marker', array['minecraft:overworld', marker]));     -- (verified)
  else
    -- (verified) `time set N`: the ticks are an int; `time add N`: a long (the clock total)
    perform mc.cmd_success(me, mc.tc_translate('commands.time.set.absolute', array[mc.tc_arg_str('minecraft:overworld'),
      case when sig = 'time/set/time' then mc.tc_arg_int((select day_time from mc.game_state)::int) else mc.tc_arg_long((select day_time from mc.game_state)) end]));
  end if;
end $$;

------------------------------------------------------------------------------------------------ /weather
create or replace function mc.cmd_run_weather(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare kind text := split_part(sig, '/', 2);
begin
  -- events only when the weather changes (the real server sent none for "weather clear" on a clear world).  The duration is accepted and ignored: dbcraft has no
  -- weather timer, so rain and thunder last until the next /weather.
  if (select raining <> (kind <> 'clear') or thundering <> (kind = 'thunder') from mc.game_state) then
    insert into mc.play_out (conn_id, data)       -- unverified: STOP_RAINING / START_RAINING, then the rain and thunder levels
      select conn_id, case when kind = 'clear' then mc.pkt_game_event(2, 0) else mc.pkt_game_event(1, 0) end
                   || mc.pkt_game_event(7, case when kind = 'clear' then 0 else 1 end) || mc.pkt_game_event(8, case when kind = 'thunder' then 1 else 0 end)
        from mc.player where conn_id is not null order by entity_id;
  end if;
  update mc.game_state set raining = kind <> 'clear', thundering = kind = 'thunder';
  perform mc.cmd_success(me, mc.tc_translate('commands.weather.set.' || kind));       -- (verified for 'clear')
end $$;

------------------------------------------------------------------------------------------------ /difficulty
create or replace function mc.cmd_run_difficulty(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare want text := nullif(split_part(sig, '/', 2), ''); n int; cur text := mc.prop('difficulty');
begin
  if want is null then
    perform mc.cmd_success(me, mc.tc_translate('commands.difficulty.query', array[mc.tc_translate('options.difficulty.' || cur)]), false); return;
  end if;
  n := case want when 'peaceful' then 0 when 'easy' then 1 when 'normal' then 2 when 'hard' then 3 end;
  if cur = want then   -- (verified) failure: already that difficulty
    perform mc.cmd_fail(me, mc.tc_translate('commands.difficulty.failure', array[mc.tc_translate('options.difficulty.' || want)]));
  else
    update mc.server_property set value = want where key = 'difficulty';
    insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_change_difficulty(n, false) from mc.player where conn_id is not null order by entity_id;
    perform mc.cmd_success(me, mc.tc_translate('commands.difficulty.success', array[mc.tc_translate('options.difficulty.' || want)]));    -- (verified)
  end if;
end $$;

------------------------------------------------------------------------------------------------ /gamemode
create or replace function mc.cmd_run_gamemode(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare mode text := args ->> 'gamemode'; gm int := case args ->> 'gamemode' when 'survival' then 0 when 'creative' then 1 when 'adventure' then 2 when 'spectator' then 3 end;
        tgts mc.player[]; t mc.player;
begin
  if args ? 'target' then tgts := mc.cmd_players(me, args -> 'target'); if tgts is null then return; end if;
  else tgts := array[mc.cmd_me(me.uuid)]; end if;
  foreach t in array tgts loop
    continue when t.gamemode = gm;                 -- unchanged: no packets, no message (verified)
    update mc.player set gamemode = gm where uuid = t.uuid;
    -- (verified order seen by the target: abilities, tab-list game mode to everyone, change-game-mode event, abilities, "Your game mode has been updated")
    insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_player_abilities(mc.gamemode_abilities(gm)));
    insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_player_info_gamemode(t.uuid, gm) from mc.player where conn_id is not null order by entity_id;
    insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_game_event(3, gm::real) || mc.pkt_player_abilities(mc.gamemode_abilities(gm)));
    if t.uuid <> me.uuid then
      perform mc.feedback(t.conn_id, mc.tc_translate('gameMode.changed', array[mc.tc_translate('gameMode.' || mode)]));
      perform mc.cmd_success(me, mc.tc_translate('commands.gamemode.success.other', array[mc.tc_player(t.uuid, t.name), mc.tc_translate('gameMode.' || mode)]));
    else
      perform mc.cmd_success(me, mc.tc_translate('commands.gamemode.success.self', array[mc.tc_translate('gameMode.' || mode)]));
    end if;
  end loop;
end $$;

------------------------------------------------------------------------------------------------ Mth.sin / Mth.cos and local coordinates
-- Vanilla's Mth.sin is a table of 65536 floats, indexed by (int)(x * 10430.378F) & 65535, and cos is the same table 16384 entries on; every step here is float arithmetic
-- (the real type), so the results are the ones the server computes, not the exact sine.
create or replace function mc.mth_sin(f real) returns real language sql immutable as $$
  select sin(((trunc((f * 10430.378::real)::float8)::bigint & 65535)::float8) * pi() * 2 / 65536)::real $$;
create or replace function mc.mth_cos(f real) returns real language sql immutable as $$
  select sin(((trunc((f * 10430.378::real + 16384::real)::float8)::bigint & 65535)::float8) * pi() * 2 / 65536)::real $$;
-- LocalCoordinates.getPosition: the offset of ^left ^up ^forwards from the position, for a view with this yaw and pitch
create or replace function mc.local_offset(p_yaw real, p_pitch real, p_left float8, p_up float8, p_fwd float8, out dx float8, out dy float8, out dz float8) language plpgsql immutable as $$
declare k real := 3.1415927::real / 180::real; f real := mc.mth_cos((p_yaw + 90::real) * k); f1 real := mc.mth_sin((p_yaw + 90::real) * k); f2 real := mc.mth_cos(-p_pitch * k);
  f3 real := mc.mth_sin(-p_pitch * k); f4 real := mc.mth_cos((-p_pitch + 90::real) * k); f5 real := mc.mth_sin((-p_pitch + 90::real) * k);
  v1x float8 := (f * f2)::float8; v1y float8 := f3::float8; v1z float8 := (f1 * f2)::float8; v2x float8 := (f * f4)::float8; v2y float8 := f5::float8; v2z float8 := (f1 * f4)::float8;
  v3x float8; v3y float8; v3z float8;
begin
  v3x := -(v1y * v2z - v1z * v2y); v3y := -(v1z * v2x - v1x * v2z); v3z := -(v1x * v2y - v1y * v2x);        -- v1 x v2, scaled by -1
  dx := v1x * p_fwd + v2x * p_up + v3x * p_left; dy := v1y * p_fwd + v2y * p_up + v3y * p_left; dz := v1z * p_fwd + v2z * p_up + v3z * p_left;
end $$;

------------------------------------------------------------------------------------------------ /teleport (/tp)
-- Forms: <destination> | <location> | <targets> <destination> | <targets> <location> [<rotation>].  `facing` is not implemented.
-- Position packets (all seen from the real server): a destination teleports to its position AND rotation (flags 0); absolute coordinates keep the target's
-- rotation (relative flags 0x18); a rotation argument sets it (flags 0, or 8/16 for a relative component); coordinates with ~ send the offsets as RELATIVE
-- flags (X Y Z and their velocity flags), and a relative y is followed by an absolute packet with the next teleport id.  Coordinates with ~ are relative to the EXECUTOR.
create or replace function mc.cmd_run_teleport(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; dst mc.player; dsts mc.player[]; loc jsonb := args -> 'location'; rot jsonb := args -> 'rotation';
        flags int; rel_x boolean; rel_y boolean; rel_z boolean; tid int; ex mc.player := mc.cmd_me(me.uuid);
        dx float8; dy float8; dz float8; ax float8; ay float8; az float8; ryaw float8; rpitch float8; nyaw float8; npitch float8; rel_yaw boolean; rel_pitch boolean; relative_any boolean;
begin
  if sig like '%facing%' then perform mc.cmd_fail(me, proto.nbt_str('text', '/teleport ... facing is not implemented in dbcraft')); return; end if;
  if args ? 'targets' then tgts := mc.cmd_players(me, args -> 'targets', true); if tgts is null then return; end if;
  else tgts := array[ex]; end if;
  if args ? 'destination' then
    dsts := mc.cmd_players(me, args -> 'destination', true); if dsts is null then return; end if;
    dst := dsts[1];
    foreach t in array tgts loop
      tid := t.teleport_id + 1;
      -- the target takes the destination's position AND rotation (vanilla: teleportToEntity)
      update mc.player set x = dst.x, y = dst.y, z = dst.z, yaw = dst.yaw, pitch = dst.pitch, chunk_x = floor(dst.x / 16)::int, chunk_z = floor(dst.z / 16)::int,
                           vis_dirty = true, teleport_id = tid, awaiting_teleport = tid where uuid = t.uuid;
      insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_player_position(tid, dst.x, dst.y, dst.z, 0, 0, 0, dst.yaw, dst.pitch, 0));
      perform mc.sync_entity_position(t.uuid);
    end loop;
    if cardinality(tgts) = 1 then
      perform mc.cmd_success(me, mc.tc_translate('commands.teleport.success.entity.single', array[mc.tc_player(tgts[1].uuid, tgts[1].name), mc.tc_player(dst.uuid, dst.name)]));
    else
      perform mc.cmd_success(me, mc.tc_translate('commands.teleport.success.entity.multiple', array[mc.tc_arg_int(cardinality(tgts)), mc.tc_player(dst.uuid, dst.name)]));
    end if;
    return;
  end if;
  -- a location, relative to the executor
  if loc ->> 0 like '^%' then
    -- local coordinates (LocalCoordinates.getPosition): left up forwards along the executor's view, as offsets from its position
    select l.dx, l.dy, l.dz into dx, dy, dz from mc.local_offset(ex.yaw, ex.pitch, coalesce(nullif(substr(loc ->> 0, 2), ''), '0')::float8,
         coalesce(nullif(substr(loc ->> 1, 2), ''), '0')::float8, coalesce(nullif(substr(loc ->> 2, 2), ''), '0')::float8) l;
    rel_x := true; rel_y := true; rel_z := true;
  else
  rel_x := loc ->> 0 like '~%'; rel_y := loc ->> 1 like '~%'; rel_z := loc ->> 2 like '~%';
  dx := case when rel_x then coalesce(nullif(substr(loc ->> 0, 2), ''), '0')::float8 else (loc ->> 0)::float8 end;
  dy := case when rel_y then coalesce(nullif(substr(loc ->> 1, 2), ''), '0')::float8 else (loc ->> 1)::float8 end;
  dz := case when rel_z then coalesce(nullif(substr(loc ->> 2, 2), ''), '0')::float8 else (loc ->> 2)::float8 end;
  end if;
  relative_any := rel_x or rel_y or rel_z;
  -- (verified) the flags: X Y Z relative = 1 2 4, rotation kept (no rotation argument) = 8 + 16, and for every relative coordinate its velocity flag too (0x20 0x40 0x80)
  flags := (case when rel_x then 1 + 32 else 0 end) | (case when rel_y then 2 + 64 else 0 end) | (case when rel_z then 4 + 128 else 0 end);
  if rot is null then flags := flags | 24; rel_yaw := false; rel_pitch := false; ryaw := 0; rpitch := 0;
  else
    rel_yaw := rot ->> 0 like '~%'; rel_pitch := rot ->> 1 like '~%';
    ryaw := case when rel_yaw then coalesce(nullif(substr(rot ->> 0, 2), ''), '0')::float8 else (rot ->> 0)::float8 end;
    rpitch := case when rel_pitch then coalesce(nullif(substr(rot ->> 1, 2), ''), '0')::float8 else (rot ->> 1)::float8 end;
    flags := flags | (case when rel_yaw then 8 else 0 end) | (case when rel_pitch then 16 else 0 end);
  end if;
  ax := case when rel_x then ex.x + dx else dx end; ay := case when rel_y then ex.y + dy else dy end; az := case when rel_z then ex.z + dz else dz end;
  foreach t in array tgts loop
    nyaw := case when rot is null then t.yaw when rel_yaw then ex.yaw + ryaw else ryaw end;
    npitch := case when rot is null then t.pitch when rel_pitch then ex.pitch + rpitch else rpitch end;
    tid := t.teleport_id + 1;
    update mc.player set x = ax, y = ay, z = az, yaw = nyaw::real, pitch = npitch::real, chunk_x = floor(ax / 16)::int, chunk_z = floor(az / 16)::int, vis_dirty = true,
                         teleport_id = tid, awaiting_teleport = tid where uuid = t.uuid;
    -- (verified) absolute coordinates: rotation kept (flags 0x18); with ~ the offsets and relative flags, then an absolute packet
    insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_player_position(tid, case when rel_x then ax - t.x else ax end, case when rel_y then ay - t.y else ay end,
                                                      case when rel_z then az - t.z else az end, 0, 0, 0, ryaw::real, rpitch::real, flags));
    if rel_y then       -- (verified) a relative y is followed by an absolute packet with the next teleport id
      update mc.player set teleport_id = tid + 1, awaiting_teleport = tid + 1 where uuid = t.uuid;
      insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_player_position(tid + 1, ax, ay, az, 0, 0, 0, nyaw::real, npitch::real, 0));
    end if;
    perform mc.sync_entity_position(t.uuid);
  end loop;
  -- vanilla centres integer coordinates on the block (10 -> 10.5): done by the parser (sql/811), the text shows what was used
  if cardinality(tgts) = 1 then
    perform mc.cmd_success(me, mc.tc_translate('commands.teleport.success.location.single', array[mc.tc_player(tgts[1].uuid, tgts[1].name),
      mc.tc_arg_str(to_char(ax, 'FM999999999990.000000')), mc.tc_arg_str(to_char(ay, 'FM999999999990.000000')), mc.tc_arg_str(to_char(az, 'FM999999999990.000000'))]));
  else
    perform mc.cmd_success(me, mc.tc_translate('commands.teleport.success.location.multiple', array[mc.tc_arg_int(cardinality(tgts)),
      mc.tc_arg_str(to_char(ax, 'FM999999999990.000000')), mc.tc_arg_str(to_char(ay, 'FM999999999990.000000')), mc.tc_arg_str(to_char(az, 'FM999999999990.000000'))]));
  end if;
end $$;

------------------------------------------------------------------------------------------------ /give
-- The inventory model stacks everything to 64 (docs/GAME.md), so the vanilla limit of 100 stacks is 6400 items (verified for stone: "Can't give more than 6400").
create or replace function mc.give_item(p_target mc.player, p_item text, p_count int) returns void language plpgsql as $$
declare rem int := p_count; chunk int; sl int; st int; add_n int; state int; changed int[]; c int;
begin
  -- GiveCommand: the count goes in as stacks of at most 64 (everything stacks to 64 here), each added like vanilla's Inventory.add: into the first slot that holds the
  -- same item and has room (hotbar first, then the main inventory), else the first empty one, continuing with the rest; after EACH stack the client is told about every
  -- slot that changed, in menu order (verified: 70 dirt on top of 4 sent slot 36 = 64, slot 37 = 4, then slot 37 = 10)
  while rem > 0 loop
    chunk := least(64, rem); rem := rem - chunk; changed := '{}';
    while chunk > 0 loop
      sl := null;
      select q.s into sl from (select generate_series(36, 44) s union all select generate_series(9, 35)) q
        where exists (select 1 from mc.inventory_slot i where i.player = p_target.uuid and i.slot = q.s and i.item = p_item and i.count < 64)
        order by (q.s >= 36) desc, q.s limit 1;
      if sl is not null then select i.count into st from mc.inventory_slot i where i.player = p_target.uuid and i.slot = sl;
      else
        select q.s into sl from (select generate_series(36, 44) s union all select generate_series(9, 35)) q
          where not exists (select 1 from mc.inventory_slot i where i.player = p_target.uuid and i.slot = q.s) order by (q.s >= 36) desc, q.s limit 1;
        st := 0;
      end if;
      exit when sl is null;                       -- a full inventory: vanilla drops the rest as an item (not modelled)
      add_n := least(64 - st, chunk);
      perform mc.set_slot(p_target.uuid, sl, p_item, st + add_n);
      chunk := chunk - add_n; changed := changed || sl;
    end loop;
    for c in select distinct x from unnest(changed) x order by x loop
      update mc.player set inv_state = inv_state + 1 where uuid = p_target.uuid returning inv_state into state;
      insert into mc.play_out (conn_id, data) values (p_target.conn_id, mc.pkt_container_set_slot(state, c, p_item, (select i.count from mc.inventory_slot i where i.player = p_target.uuid and i.slot = c)));
    end loop;
  end loop;
end $$;

create or replace function mc.cmd_run_give(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; item text := args ->> 'item'; n int := coalesce((args ->> 'count')::int, 1);
begin
  tgts := mc.cmd_players(me, args -> 'targets'); if tgts is null then return; end if;
  if n > 6400 then
    perform mc.cmd_fail(me, mc.tc_translate('commands.give.failed.toomanyitems', array[mc.tc_arg_int(6400), mc.tc_item(item)])); return;
  end if;
  foreach t in array tgts loop perform mc.give_item(t, item, n); end loop;
  if cardinality(tgts) = 1 then
    perform mc.cmd_success(me, mc.tc_translate('commands.give.success.single', array[mc.tc_arg_int(n), mc.tc_item(item), mc.tc_player(tgts[1].uuid, tgts[1].name)]));
  else
    perform mc.cmd_success(me, mc.tc_translate('commands.give.success.multiple', array[mc.tc_arg_int(n), mc.tc_item(item), mc.tc_arg_int(cardinality(tgts))]));
  end if;
end $$;

------------------------------------------------------------------------------------------------ /op /deop
-- PlayerList.op: the new operator gets entity_event 24 + level, then the command tree of the new level; /deop does the same with level 0.
create or replace function mc.send_permission_level(p_uuid uuid) returns void language plpgsql as $$
declare p mc.player := mc.cmd_me(p_uuid); lvl int := mc.permission_level(p_uuid);
begin
  if p.conn_id is null then return; end if;
  insert into mc.play_out (conn_id, data) values (p.conn_id, mc.pkt_entity_event(p.entity_id, 24 + lvl));
  insert into mc.play_out (conn_id, data) values (p.conn_id, mc.pkt_commands(lvl));
end $$;

create or replace function mc.cmd_run_op(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; n int := 0;
begin
  tgts := mc.cmd_profiles(me, args -> 'targets'); if tgts is null then return; end if;
  foreach t in array tgts loop
    continue when exists (select 1 from mc.op where uuid = t.uuid);
    insert into mc.op (uuid, name, level) values (t.uuid, t.name, mc.prop_int('op-permission-level'));
    n := n + 1;
    perform mc.send_permission_level(t.uuid);
    perform mc.cmd_success(me, mc.tc_translate_strs('commands.op.success', array[t.name]));      -- (verified: {with: list<string>[name], translate})
  end loop;
  if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.op.failed')); end if;
end $$;

create or replace function mc.cmd_run_deop(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; n int := 0;
begin
  tgts := mc.cmd_profiles(me, args -> 'targets'); if tgts is null then return; end if;
  foreach t in array tgts loop
    continue when not exists (select 1 from mc.op where uuid = t.uuid);
    delete from mc.op where uuid = t.uuid;
    n := n + 1;
    perform mc.send_permission_level(t.uuid);
    perform mc.cmd_success(me, mc.tc_translate_strs('commands.deop.success', array[t.name]));
  end loop;
  if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.deop.failed')); end if;
end $$;

------------------------------------------------------------------------------------------------ /whitelist
create or replace function mc.cmd_run_whitelist(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; names text[]; n int := 0; verb text := split_part(sig, '/', 2); on_ boolean := mc.prop_bool('white-list');
begin
  if verb = 'list' then
    select array_agg(name order by name) into names from mc.whitelist;
    if names is null then perform mc.cmd_success(me, mc.tc_translate('commands.whitelist.none'), false);          -- (verified)
    else perform mc.cmd_success(me, mc.tc_translate('commands.whitelist.list', array[mc.tc_arg_int(cardinality(names)), mc.tc_arg_str(array_to_string(names, ', '))]), false); end if;   -- (verified)
  elsif verb in ('add', 'remove') then
    tgts := mc.cmd_profiles(me, args -> 'targets'); if tgts is null then return; end if;
    foreach t in array tgts loop
      if verb = 'add' then
        continue when exists (select 1 from mc.whitelist where uuid = t.uuid);
        insert into mc.whitelist values (t.uuid, t.name);
      else
        continue when not exists (select 1 from mc.whitelist where uuid = t.uuid);
        delete from mc.whitelist where uuid = t.uuid;
      end if;
      n := n + 1;
      perform mc.cmd_success(me, mc.tc_translate_strs('commands.whitelist.' || verb || '.success', array[t.name]));   -- (verified: list<string>)
    end loop;
    if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.whitelist.' || verb || '.failed')); end if;
  elsif verb in ('on', 'off') then
    if on_ = (verb = 'on') then perform mc.cmd_fail(me, mc.tc_translate(case verb when 'on' then 'commands.whitelist.alreadyOn' else 'commands.whitelist.alreadyOff' end)); return; end if;
    update mc.server_property set value = (verb = 'on')::text where key = 'white-list';
    perform mc.cmd_success(me, mc.tc_translate(case verb when 'on' then 'commands.whitelist.enabled' else 'commands.whitelist.disabled' end));   -- (verified)
  elsif verb = 'reload' then
    perform mc.cmd_success(me, mc.tc_translate('commands.whitelist.reloaded'));
  end if;
end $$;

------------------------------------------------------------------------------------------------ /ban /pardon
create or replace function mc.cmd_run_ban(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; reason text := coalesce(nullif(args #>> '{reason,text}', ''), 'Banned by an operator.'); n int := 0;
begin
  tgts := mc.cmd_profiles(me, args -> 'targets'); if tgts is null then return; end if;
  foreach t in array tgts loop
    continue when exists (select 1 from mc.ban where kind = 'player' and uuid = t.uuid);
    insert into mc.ban (kind, uuid, name, reason, source) values ('player', t.uuid, t.name, reason, me.name);
    n := n + 1;
    -- (verified: the disconnect text carries no reason)
    if t.conn_id is not null then perform mc.kick(t.conn_id, 'multiplayer.disconnect.banned'); end if;
    -- (verified) a given reason: two plain strings; without one the reason is the translatable default text
    if nullif(args #>> '{reason,text}', '') is not null then perform mc.cmd_success(me, mc.tc_translate_strs('commands.ban.success', array[t.name, reason]));
    else perform mc.cmd_success(me, mc.tc_translate('commands.ban.success', array[mc.tc_arg_str(t.name), proto.nbt_str('translate', 'multiplayer.disconnect.banned.reason.default')])); end if;
  end loop;
  if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.ban.failed')); end if;
end $$;

create or replace function mc.cmd_run_pardon(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; n int := 0;
begin
  tgts := mc.cmd_profiles(me, args -> 'targets'); if tgts is null then return; end if;
  foreach t in array tgts loop
    continue when not exists (select 1 from mc.ban where kind = 'player' and uuid = t.uuid);
    delete from mc.ban where kind = 'player' and uuid = t.uuid;
    n := n + 1;
    perform mc.cmd_success(me, mc.tc_translate_strs('commands.pardon.success', array[t.name]));      -- (verified)
  end loop;
  if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.pardon.failed')); end if;
end $$;
