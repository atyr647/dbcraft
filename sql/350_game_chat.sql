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

-- The commands and the permission level that unlocks each of them are the rows of mc.cmd_node (sql/810): the command graph vanilla sends to clients.  This table is
-- NOT consulted any more; it stays (empty) so that module files written against the old dispatcher, which register a command here, still load.
create table if not exists mc.command (name text primary key, level int not null check (level between 0 and 4), usage text);

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
  -- dbcraft.vanilla-tracker (sql/907): the tracker sends what vanilla sends after a teleport -- the connection of the locator bar is remade and the next movement step is a
  -- full position sync (the jump is too big for a delta), the player is off the ground until the entity phase of the next tick -- so nothing is sent here
  if mc.vis_on() then
    update mc.player set on_ground = false, tp_ground_tick = (select game_time from mc.game_state) + 1 where uuid = p_uuid;
    return;
  end if;
  -- Only a jump that vanilla's entity tracker sends as a TELEPORT (a delta that does not fit in a short, more than 8 blocks: the movement step's own test) is
  -- handled here.  A shorter /tp stays a relative move sent by the next movement step, exactly as before (tests/sql/36 pins those bytes, vanilla does the same),
  -- and the stale base is then at most 8 blocks from the real position, which a new viewer's loaded area still contains.
  if abs(mc.quant(p.x) - p.sent_qx) <= 32767 and abs(mc.quant(p.y) - p.sent_qy) <= 32767 and abs(mc.quant(p.z) - p.sent_qz) <= 32767 then return; end if;
  insert into mc.play_out (conn_id, data)
    select v.viewer_conn, mc.pkt_teleport_entity(p.entity_id, p.x, p.y, p.z, 0, 0, 0, p.yaw, p.pitch, p.on_ground) || mc.pkt_rotate_head(p.entity_id, p.yaw)
      from mc.visible v where v.target_eid = p.entity_id and v.viewer_conn <> p.conn_id order by v.viewer_conn;
  update mc.player set sent_qx = mc.quant(x), sent_qy = mc.quant(y), sent_qz = mc.quant(z), sent_yaw = yaw, sent_pitch = pitch where uuid = p_uuid;
end $$;

-- A chat_command packet: the dispatcher is sql/813 (mc.cmd_execute), driven by the parse of the command graph (sql/811).
create or replace function mc.run_command(p_conn int, cmd text) returns void language plpgsql as $$
begin perform mc.cmd_execute(p_conn, cmd); end $$;
