-- Player visibility, part 2: clientbound packet builders (whole frames).  Layouts from the 26.3 classes (tools/pkt_layout.py, javap) and the real server's packets:
--   set_entity_data  = VarInt entity | { byte index | VarInt serializer | value }* | 0xff
--                      player entries: 0 flags (byte: 0x01 on fire, 0x02 crouching, 0x08 sprinting, 0x10 swimming, 0x20 invisible, 0x40 glowing, 0x80 gliding), 6 pose (serializer 20, VarInt),
--                      8 living flags (byte: 0x01 using an item), 9 health (float), 15 main arm (serializer 42, VarInt 0 left / 1 right), 16 skin layers (byte), 18 score (VarInt)
--   set_equipment    = VarInt entity | { byte slot | 0x80 when another entry follows ; ItemStack (VarInt count, [VarInt item, VarInt added, VarInt removed, components]) }
--                      slots: 0 main hand, 1 off hand, 2 feet, 3 legs, 4 chest, 5 head; ascending order
--   update_attributes= VarInt entity | VarInt count | { VarInt attribute id | double base | VarInt modifier count | { string id | double amount | byte operation }* }*
--   swing_animation  = VarInt entity | VarInt hand | VarInt swing type (1 whack, 2 stab) | VarInt duration
--   player_info_update actions: 0x10 UPDATE_LATENCY (VarInt), 0x80 UPDATE_HAT (bool)

-- the entries of set_entity_data for the indexes in the mask: 1 flags, 2 pose, 4 using an item, 8 health, 16 main arm, 32 skin layers, 64 score; index order
create or replace function mc.ed_entries(p_flags int, p_pose int, p_using int, p_health real, p_arm int, p_skin int, p_score int, p_mask int) returns bytea language sql immutable parallel safe as $$
  select (case when p_mask & 1  <> 0 then '\x0000'::bytea || proto.i8(p_flags) else '\x'::bytea end)
      || (case when p_mask & 2  <> 0 then '\x0614'::bytea || proto.varint(p_pose) else '\x'::bytea end)
      || (case when p_mask & 4  <> 0 then '\x0800'::bytea || proto.i8(p_using) else '\x'::bytea end)
      || (case when p_mask & 8  <> 0 then '\x0903'::bytea || proto.f32(p_health) else '\x'::bytea end)
      || (case when p_mask & 16 <> 0 then '\x0f2a'::bytea || proto.varint(p_arm) else '\x'::bytea end)
      || (case when p_mask & 32 <> 0 then '\x1000'::bytea || proto.i8(p_skin) else '\x'::bytea end)
      || (case when p_mask & 64 <> 0 then '\x1201'::bytea || proto.varint(p_score) else '\x'::bytea end)
      || '\xff'::bytea $$;

create or replace function mc.pkt_entity_data(p_eid int, p_entries bytea) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_entity_data', proto.varint(p_eid) || p_entries) $$;

create or replace function mc.pkt_bundle_delimiter() returns bytea language sql immutable parallel safe as $$ select '\x0100'::bytea $$;      -- packet id 0, empty body

-- set_equipment for the slots (EquipmentSlot ordinals, ascending) with the given stacks (hex of the wire form; '' = empty)
create or replace function mc.pkt_equipment(p_eid int, p_slots int[], p_stacks text[]) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_equipment', proto.varint(p_eid)
         || (select string_agg(proto.i8(t.s | case when t.o < cardinality(p_slots) then 128 else 0 end) || case when t.h = '' then '\x00'::bytea else decode(t.h, 'hex') end, '\x'::bytea order by t.o)
               from unnest(p_slots, p_stacks) with ordinality t(s, h, o))) $$;

-- update_attributes: the entries are the per-attribute byte strings (id, base, modifiers)
create or replace function mc.pkt_update_attributes(p_eid int, p_entries bytea[]) returns bytea language sql stable parallel safe as $$
  select mc.cb('update_attributes', proto.varint(p_eid) || proto.varint(cardinality(p_entries)) || proto.cat(p_entries)) $$;

create or replace function mc.pkt_swing(p_eid int, p_hand int, p_type int, p_duration int) returns bytea language sql stable parallel safe as $$
  select mc.cb('swing_animation', proto.varint(p_eid) || proto.varint(p_hand) || proto.varint(p_type) || proto.varint(p_duration)) $$;

create or replace function mc.pkt_player_info_hat(p_uuid uuid, p_hat boolean) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_info_update', '\x80'::bytea || proto.varint(1) || proto.uuid(p_uuid) || proto.bool(p_hat)) $$;
create or replace function mc.pkt_player_info_latencies(p_uuids uuid[], p_latencies int[]) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_info_update', '\x10'::bytea || proto.varint(cardinality(p_uuids))
         || (select string_agg(proto.uuid(t.u) || proto.varint(t.l), '\x'::bytea order by t.o) from unnest(p_uuids, p_latencies) with ordinality t(u, l, o))) $$;

-- the players' attribute model.  Which attributes a client is sent (Attribute.isClientSyncable) and their base values (Attributes / Player.createAttributes), by registry id.
create or replace function mc.attr_syncable(p_id int) returns boolean language sql immutable parallel safe as $$
  select p_id not in (3, 4, 16, 20, 32, 36, 38, 39) $$;                       -- attack_damage, attack_knockback, follow_range, knockback_resistance, spawn_reinforcements, tempt_range, waypoint_transmit_range, waypoint_receive_range
create or replace function mc.attr_base(p_id int) returns float8 language sql immutable parallel safe as $$
  select case p_id when 0 then 1.0 when 5 then 4.0 when 6 then 10.0 when 7 then 1.0 when 8 then 4.5 when 10 then 1.0 when 11 then 4.0 when 13 then 3.0 when 14 then 1.0
                   when 15 then 0.4 when 17 then 1.0 when 18 then 0.08 when 19 then 0.41999998688697815 when 22 then 0.0 when 23 then 20.0 when 26 then 0.10000000149011612 when 27 then 64.0
                   when 29 then 3.0 when 30 then 1.0 when 31 then 0.3 when 33 then 0.6 when 34 then 0.2 else 0.0 end $$;
