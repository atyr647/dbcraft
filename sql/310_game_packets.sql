-- Game module, part 2: clientbound play packet builders (each returns a whole frame: [length][id][body], compression off).
-- Layouts were read from the 26.3 bytecode (tools/pkt_layout.py) and compared with packets captured from the real server (tests/game_verify.py).

create or replace function mc.pid(pname text) returns int language sql stable parallel safe as $$
  select protocol_id from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:' || pname $$;

create or replace function mc.cb(pname text, body bytea) returns bytea language sql stable parallel safe as $$ select proto.frame(mc.pid(pname), body) $$;

-- Angles on the wire are one byte: floor(degrees * 256 / 360), as Mth.floor does it in float arithmetic.
create or replace function mc.angle_byte(deg real) returns int language sql immutable parallel safe as $$
  select (floor((deg * 256::real) / 360::real)::int) & 255 $$;
-- Quantised position used by relative movement: 1/4096 of a block.
create or replace function mc.quant(v float8) returns bigint language sql immutable parallel safe as $$ select round(v * 4096.0)::bigint $$;

------------------------------------------------------------------------------------------------ chat
-- system_chat: Component (network NBT) + overlay flag (true = action bar)
create or replace function mc.pkt_system_chat(component_nbt bytea, is_overlay boolean default false) returns bytea language sql stable parallel safe as $$
  select mc.cb('system_chat', component_nbt || proto.bool(is_overlay)) $$;

-- player_chat: globalIndex, sender, index, signature (none: offline), body {message, timestamp ms, salt, lastSeen=0 entries}, unsigned content (none),
-- filter mask 0 (pass through), chat type holder (registry id + 1), sender display name component, target name (none)
create or replace function mc.pkt_player_chat(global_index int, sender uuid, msg_index int, message text, ts_ms bigint, salt bigint, chat_type_id int, sender_name_fields bytea)
returns bytea language sql stable parallel safe as $$
  select mc.cb('player_chat', proto.varint(global_index) || proto.uuid(sender) || proto.varint(msg_index) || proto.bool(false)
       || proto.string(message) || proto.i64(ts_ms) || proto.i64(salt) || proto.varint(0)
       || proto.bool(false) || proto.varint(0) || proto.varint(chat_type_id + 1) || proto.nbt_root(sender_name_fields) || proto.bool(false)) $$;

------------------------------------------------------------------------------------------------ tab list (player_info_update / remove)
-- actions are a 1-byte bit set: 0 ADD_PLAYER, 1 INITIALIZE_CHAT, 2 UPDATE_GAME_MODE, 3 UPDATE_LISTED, 4 UPDATE_LATENCY, 5 UPDATE_DISPLAY_NAME, 6 UPDATE_LIST_ORDER, 7 UPDATE_HAT.
-- Entry for the "all actions" form vanilla sends when a player joins.
create or replace function mc.pie_add(p_uuid uuid, p_name text, gamemode int, listed boolean default true, latency int default 0, list_order int default 0, hat boolean default false)
returns bytea language sql immutable parallel safe as $$
  select proto.uuid(p_uuid) || proto.string(p_name) || proto.varint(0)      -- name, 0 profile properties (textures: offline mode has none)
      || proto.bool(false)                                                   -- chat session: none
      || proto.varint(gamemode) || proto.bool(listed) || proto.varint(latency)
      || proto.bool(false)                                                   -- display name: none
      || proto.varint(list_order) || proto.bool(hat) $$;
create or replace function mc.pkt_player_info_add(entries bytea[]) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_info_update', '\xff'::bytea || proto.varint(array_length(entries, 1)) || proto.cat(entries)) $$;
create or replace function mc.pkt_player_info_gamemode(p_uuid uuid, gamemode int) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_info_update', '\x04'::bytea || proto.varint(1) || proto.uuid(p_uuid) || proto.varint(gamemode)) $$;
create or replace function mc.pkt_player_info_latency(p_uuid uuid, latency int) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_info_update', '\x10'::bytea || proto.varint(1) || proto.uuid(p_uuid) || proto.varint(latency)) $$;
create or replace function mc.pkt_player_info_remove(uuids uuid[]) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_info_remove', proto.varint(array_length(uuids, 1)) || (select string_agg(proto.uuid(u), '\x'::bytea order by ord) from unnest(uuids) with ordinality t(u, ord))) $$;

------------------------------------------------------------------------------------------------ entities
-- add_entity: id, uuid, type (registry id; player = ref 'minecraft:entity_type'/'minecraft:player'), position, velocity (low-precision vec3: 0x00 = zero), rotations, data.
create or replace function mc.entity_type_id(tname text) returns int language sql stable parallel safe as $$
  select protocol_id from ref.registry where registry = 'minecraft:entity_type' and name = tname $$;
create or replace function mc.pkt_add_player_entity(entity_id int, p_uuid uuid, x float8, y float8, z float8, yaw real, pitch real, head_yaw real)
returns bytea language sql stable parallel safe as $$
  select mc.cb('add_entity', proto.varint(entity_id) || proto.uuid(p_uuid) || proto.varint(mc.entity_type_id('minecraft:player'))
       || proto.f64(x) || proto.f64(y) || proto.f64(z) || '\x00'::bytea
       || proto.i8(mc.angle_byte(pitch)) || proto.i8(mc.angle_byte(yaw)) || proto.i8(mc.angle_byte(head_yaw)) || proto.varint(0)) $$;
create or replace function mc.pkt_remove_entities(ids int[]) returns bytea language sql stable parallel safe as $$
  select mc.cb('remove_entities', proto.varint(array_length(ids, 1)) || (select string_agg(proto.varint(i), '\x'::bytea order by ord) from unnest(ids) with ordinality t(i, ord))) $$;

-- Relative movement: [entity VarInt][flags VarInt: bit0 on ground, bits1.. step count][step: ticks VarInt + 3 shorts (1/4096 block)].
-- Vanilla sends one step whose `ticks` is the time since the entity's last update; that is what ticks means here.
create or replace function mc.delta_steps(dx int, dy int, dz int, ticks int) returns bytea language sql immutable parallel safe as $$
  select proto.varint(ticks) || proto.i16(dx) || proto.i16(dy) || proto.i16(dz) $$;
create or replace function mc.pkt_move_entity_pos(entity_id int, dx int, dy int, dz int, ticks int, on_ground boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('move_entity_pos', proto.varint(entity_id) || proto.varint((case when on_ground then 1 else 0 end) | (1 << 1)) || mc.delta_steps(dx, dy, dz, ticks)) $$;
create or replace function mc.pkt_move_entity_pos_rot(entity_id int, dx int, dy int, dz int, ticks int, yaw real, pitch real, on_ground boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('move_entity_pos_rot', proto.varint(entity_id) || proto.varint((case when on_ground then 1 else 0 end) | (1 << 1)) || mc.delta_steps(dx, dy, dz, ticks)
       || proto.i8(mc.angle_byte(yaw)) || proto.i8(mc.angle_byte(pitch))) $$;
create or replace function mc.pkt_move_entity_rot(entity_id int, yaw real, pitch real, on_ground boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('move_entity_rot', proto.varint(entity_id) || proto.bool(on_ground) || proto.i8(mc.angle_byte(yaw)) || proto.i8(mc.angle_byte(pitch))) $$;
create or replace function mc.pkt_rotate_head(entity_id int, head_yaw real) returns bytea language sql stable parallel safe as $$
  select mc.cb('rotate_head', proto.varint(entity_id) || proto.i8(mc.angle_byte(head_yaw))) $$;

-- player_position: teleport the receiving player.  teleport id, position, delta movement, yaw, pitch, relative-flags int (0 = all absolute)
create or replace function mc.pkt_player_position(teleport_id int, x float8, y float8, z float8, dx float8, dy float8, dz float8, yaw real, pitch real, relative int default 0)
returns bytea language sql stable parallel safe as $$
  select mc.cb('player_position', proto.varint(teleport_id) || proto.f64(x) || proto.f64(y) || proto.f64(z) || proto.f64(dx) || proto.f64(dy) || proto.f64(dz)
       || proto.f32(yaw) || proto.f32(pitch) || proto.i32(relative)) $$;

create or replace function mc.pkt_keep_alive(id bigint) returns bytea language sql stable parallel safe as $$ select mc.cb('keep_alive', proto.i64(id)) $$;
