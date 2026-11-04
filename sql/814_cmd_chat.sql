-- Commands, part 5: the chat-like commands and the small information commands: /say /me /msg (/tell /w) /seed /help /gamerule /clear.
-- Keys, component shapes and packet order were read from a real 26.3 server (tests/e2e/compare_commands.py compares them byte for byte).

------------------------------------------------------------------------------------------------ /say /me /msg
-- /say and /me broadcast a disguised_chat (chat type say_command / emote_command) to every player; the content is the message with its selectors resolved.
create or replace function mc.cmd_broadcast_chat(me mc.player, p_type text, p_msg jsonb) returns void language plpgsql as $$
declare root bytea := mc.msg_component_root(me, p_msg);
begin
  insert into mc.play_out (conn_id, data)
    select conn_id, mc.pkt_disguised_chat_root(root, mc.chat_type_id(p_type), mc.tc_player(me.uuid, me.name)) from mc.player where conn_id is not null order by entity_id;
end $$;

create or replace function mc.cmd_run_say(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
begin
  insert into mc.chat_log (kind, sender, sender_name, message) values ('say', me.uuid, me.name, btrim(args #>> '{message,text}'));
  perform mc.cmd_broadcast_chat(me, 'minecraft:say_command', args -> 'message');
end $$;

create or replace function mc.cmd_run_me(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
begin
  perform mc.cmd_broadcast_chat(me, 'minecraft:emote_command', args -> 'action');
end $$;

-- /msg: for every target, in order: the "You whisper to X" line to the sender, then the "X whispers to you" line to the target (MsgCommand.sendMessage)
create or replace function mc.cmd_run_msg(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; root bytea; out_t int := mc.chat_type_id('minecraft:msg_command_outgoing'); in_t int := mc.chat_type_id('minecraft:msg_command_incoming');
begin
  tgts := mc.cmd_players(me, args -> 'targets'); if tgts is null then return; end if;
  root := mc.msg_component_root(me, args -> 'message');
  foreach t in array tgts loop
    insert into mc.play_out (conn_id, data) values (me.conn_id, mc.pkt_disguised_chat_root(root, out_t, mc.tc_player(me.uuid, me.name), mc.tc_player(t.uuid, t.name)));
    insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_disguised_chat_root(root, in_t, mc.tc_player(me.uuid, me.name)));
  end loop;
end $$;

------------------------------------------------------------------------------------------------ /seed
-- The world seed: the server property level-seed when it is set (a number, or a text hashed like Java's String.hashCode), else a random one kept in
-- mc.world_seed from the first time anybody asks.
create table if not exists mc.world_seed (id int primary key default 1 check (id = 1), seed bigint not null);
create or replace function mc.java_string_hash(s text) returns int language plpgsql immutable as $$
declare h bigint := 0; c int;
begin
  for c in select ascii(ch) from regexp_split_to_table(s, '') ch loop h := ((h * 31 + c) & 4294967295); end loop;
  return case when h >= 2147483648 then (h - 4294967296)::int else h::int end;
end $$;
create or replace function mc.world_seed_get() returns bigint language plpgsql as $$
declare v text := nullif(btrim(coalesce(mc.prop('level-seed'), '')), ''); s bigint;
begin
  if v is not null then   -- Long.parseLong, else String.hashCode
    return case when v ~ '^-?[0-9]{1,19}$' and v::numeric between -9223372036854775808 and 9223372036854775807 then v::bigint else mc.java_string_hash(v) end;
  end if;
  select seed into s from mc.world_seed;
  if s is null then
    s := ('x' || substr(md5(random()::text || clock_timestamp()::text), 1, 16))::bit(64)::bigint;
    insert into mc.world_seed (seed) values (s);
  end if;
  return s;
end $$;
create or replace function mc.cmd_run_seed(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare s text := mc.world_seed_get()::text;
begin
  perform mc.cmd_success(me, mc.tc_translate('commands.seed.success', array[proto.cat(array[
    proto.nbt_list_comp('with', array[proto.cat(array[
      proto.nbt_comp('click_event', proto.nbt_str('action', 'copy_to_clipboard'), proto.nbt_str('value', s)), proto.nbt_str('color', 'green'),
      proto.nbt_str('insertion', s), proto.nbt_str('text', s),
      proto.nbt_comp('hover_event', proto.nbt_str('action', 'show_text'), proto.nbt_comp('value', proto.nbt_str('translate', 'chat.copy.click')))])]),
    proto.nbt_str('translate', 'chat.square_brackets')])]), false);
end $$;

------------------------------------------------------------------------------------------------ /help
-- Usage text from the graph: CommandDispatcher.getSmartUsage (read from the library's bytecode).  [x] optional, (a|b) alternatives, <x> argument,
-- "-> target" for an alias.  /help alone lists every command the player may use; /help <command> lists what may follow it.
create or replace function mc.cmd_usage_text(p_node int) returns text language sql stable as $$
  select case kind when 1 then name when 2 then '<' || name || '>' else '' end from mc.cmd_node where id = p_node $$;

create or replace function mc.cmd_usage(p_node int, p_level int, p_optional boolean, p_deep boolean) returns text language plpgsql stable as $$
declare n mc.cmd_node; self text; child_opt boolean; kids int[]; us text[] := '{}'; u text; k int; uniq text[] := '{}'; names text[] := '{}';
begin
  select * into n from mc.cmd_node where id = p_node;
  if n.min_level > p_level then return null; end if;
  self := case when p_optional then '[' || mc.cmd_usage_text(p_node) || ']' else mc.cmd_usage_text(p_node) end;
  child_opt := n.executable;
  if p_deep then return self; end if;
  if n.redirect is not null then
    return self || ' ' || case when n.redirect = 0 then '...' else '-> ' || mc.cmd_usage_text(n.redirect) end;
  end if;
  select array_agg(c.child order by c.pos) into kids from mc.cmd_child c join mc.cmd_node x on x.id = c.child where c.parent = p_node and x.min_level <= p_level;
  if cardinality(kids) = 1 then
    u := mc.cmd_usage(kids[1], p_level, child_opt, child_opt);
    if u is not null then return self || ' ' || u; end if;
  elsif cardinality(kids) > 1 then
    foreach k in array kids loop
      u := mc.cmd_usage(k, p_level, child_opt, true);
      if u is not null and not u = any (uniq) then uniq := uniq || u; end if;
      names := names || mc.cmd_usage_text(k);
    end loop;
    if cardinality(uniq) = 1 then return self || ' ' || case when child_opt then '[' || uniq[1] || ']' else uniq[1] end; end if;
    if cardinality(uniq) > 1 then
      return self || ' ' || case when child_opt then '[' else '(' end || array_to_string(names, '|') || case when child_opt then ']' else ')' end;
    end if;
  end if;
  return self;
end $$;

create or replace function mc.cmd_run_help(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare cmd text := args ->> 'command'; pr mc.cmd_pr; last_node int; kid record; u text;
begin
  if cmd is null then last_node := 0;
  else
    pr := mc.cmd_parse_nodes(0, cmd, 0, lvl, 0, lvl >= 2);
    if cardinality(pr.top) = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.help.failed')); return; end if;
    last_node := pr.top[cardinality(pr.top)];
  end if;
  for kid in select c.child from mc.cmd_child c where c.parent = last_node order by c.pos loop
    u := mc.cmd_usage(kid.child, lvl, (select executable from mc.cmd_node where id = last_node), false);
    if u is not null then perform mc.cmd_success_text(me, '/' || coalesce(cmd || ' ', '') || u); end if;
  end loop;
end $$;

------------------------------------------------------------------------------------------------ /gamerule
-- gamerule <rule> queries, gamerule <rule> <value> sets.  Values were checked against the range in the graph by the parser.  reduced_debug_info is the one rule that
-- sends a packet when it changes (entity_event 22 / 23 to everybody; verified: immediate_respawn and limited_crafting send nothing here).
create or replace function mc.cmd_run_gamerule(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare rule text := regexp_replace(split_part(sig, '/', 2), '^minecraft:', ''); d mc.gamerule_default; cur text; v text;
begin
  select * into d from mc.gamerule_default where name = rule;
  if not found then perform mc.cmd_fail(me, proto.nbt_str('text', 'the game rule ' || rule || ' is not implemented in dbcraft')); return; end if;
  cur := mc.gamerule_get(rule);
  if cardinality(string_to_array(sig, '/')) = 2 then
    perform mc.cmd_success(me, mc.tc_translate_strs('commands.gamerule.query', array[rule, cur]), false); return;
  end if;
  v := args ->> 'value';
  if v = cur then perform mc.cmd_fail(me, mc.tc_translate_strs('commands.gamerule.not_set', array[rule, v])); return; end if;
  insert into mc.game_rule (name, value) values ('minecraft:' || rule, v) on conflict (name) do update set value = excluded.value;
  if rule = 'reduced_debug_info' then
    insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_entity_event(entity_id, case when v = 'true' then 22 else 23 end) from mc.player where conn_id is not null order by entity_id;
  end if;
  perform mc.cmd_success(me, mc.tc_translate_strs('commands.gamerule.set', array[rule, v]));       -- (verified; with send_command_feedback off, nothing is said at all)
end $$;

------------------------------------------------------------------------------------------------ /clear
-- Removes matching items from the targets' inventories (hotbar, main inventory, armor, off hand - the order of vanilla's compartments), then tells each target's
-- client: a container_set_slot for every changed slot, and for the crafting-result slot 0 (Inventory slotsChanged: sent even when nothing matched).
create or replace function mc.cmd_run_clear(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; v_item text := args ->> 'item'; maxc int := (args ->> 'maxCount')::int; total int := 0; affected int := 0; found int; removed int; s record; state int; left_n int;
begin
  if args ? 'targets' then tgts := mc.cmd_players(me, args -> 'targets'); if tgts is null then return; end if;
  else tgts := array[mc.cmd_me(me.uuid)]; end if;
  foreach t in array tgts loop
    found := 0; left_n := coalesce(maxc, 2147483647);
    for s in select slot, mc.inventory_slot.item as it, count from mc.inventory_slot
              where player = t.uuid and (v_item is null or v_item = '*' or mc.inventory_slot.item = v_item)
              order by case when slot between 36 and 44 then 0 when slot between 9 and 35 then 1 when slot between 5 and 8 then 2 else 3 end,
                       case when slot between 5 and 8 then -slot else slot end loop
      if maxc = 0 then found := found + s.count; continue; end if;       -- maxCount 0: only count
      removed := least(s.count, left_n); continue when removed <= 0;
      left_n := left_n - removed; found := found + removed;
      if removed = s.count then perform mc.set_slot(t.uuid, s.slot, null, 0); else perform mc.set_slot(t.uuid, s.slot, s.it, s.count - removed); end if;
      update mc.player set inv_state = inv_state + 1 where uuid = t.uuid returning inv_state into state;
      insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_container_set_slot(state, s.slot, s.it, s.count - removed));
    end loop;
    if maxc is distinct from 0 then       -- (verified) counting only (maxCount 0) sends nothing to the target
      update mc.player set inv_state = inv_state + 1 where uuid = t.uuid returning inv_state into state;
      insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_container_set_slot(state, 0, null, 0));
    end if;
    total := total + found; if found > 0 then affected := affected + 1; end if;      -- (verified) "from N players" counts the players that lost something
  end loop;
  if total = 0 then
    perform mc.cmd_fail(me, case when cardinality(tgts) = 1 then mc.tc_translate('clear.failed.single', array[mc.tc_player(tgts[1].uuid, tgts[1].name)])
                                 else mc.tc_translate_json('clear.failed.multiple', jsonb_build_array(cardinality(tgts))) end);
  elsif maxc = 0 then
    perform mc.cmd_success(me, case when cardinality(tgts) = 1 then mc.tc_translate('commands.clear.test.single', array[mc.tc_arg_int(total), mc.tc_player(tgts[1].uuid, tgts[1].name)])
                                    else mc.tc_translate_json('commands.clear.test.multiple', jsonb_build_array(total, affected)) end);
  else
    perform mc.cmd_success(me, case when cardinality(tgts) = 1 then mc.tc_translate('commands.clear.success.single', array[mc.tc_arg_int(total), mc.tc_player(tgts[1].uuid, tgts[1].name)])
                                    else mc.tc_translate_json('commands.clear.success.multiple', jsonb_build_array(total, affected)) end);
  end if;
end $$;
