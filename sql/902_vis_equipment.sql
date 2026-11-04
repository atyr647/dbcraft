-- Player visibility, part 3: what a player wears and carries, and the attributes that follow from it.
--
-- Equipment (LivingEntity.detectEquipmentUpdates, ServerEntity.sendPairingData): the six slots main hand, off hand, feet, legs, chest, head, compared per slot with what
-- was last broadcast (ItemStack.matches: item, count and components); a changed slot is sent to the viewers (not to the player) as set_equipment, a viewer who starts
-- seeing the player gets every non-empty slot with the add_entity.  The inventory is the player menu's numbering (mc.inventory_slot): 5-8 armor (head to feet), 36-44 hotbar,
-- 45 off hand.
-- Attributes (AttributeMap.getSyncableAttributes, ServerPlayer / LivingEntity dirty attributes): movement speed with the sprinting modifier, the two interaction ranges (creative
-- mode adds a modifier to each), and the modifiers of the items in their slots (armor, armor toughness, attack speed, ...: ref.item_attr).  An attribute that is not in the
-- player's map is not listed when a viewer starts seeing the player: instances are created lazily in vanilla, modelled here by the bit mask mc.player.attr_seen.

create or replace function mc.attr_id(p_name text) returns int language sql stable as $$
  select protocol_id from ref.registry where registry = 'minecraft:attribute' and name = p_name $$;

-- the six visible stacks of a player: hex of the wire form (VarInt count, VarInt item, the components as stored) or '' for an empty slot, in EquipmentSlot order
create or replace function mc.equip_now(p_uuid uuid, p_held int) returns text[] language sql stable as $$
  select array_agg(coalesce(x.h, '') order by o.ord)
    from (values (0, 36 + p_held), (1, 45), (2, 8), (3, 7), (4, 6), (5, 5)) o(ord, slot)
    left join lateral (select encode(proto.varint(i.count::int) || proto.varint(mc.item_id(i.item)) || coalesce(decode(i.components ->> 'raw_hex', 'hex'), '\x0000'::bytea), 'hex') as h
                         from mc.inventory_slot i where i.player = p_uuid and i.slot = o.slot) x on true $$;

-- the attribute entries (VarInt id, double base, VarInt modifier count, modifiers) a player has now, as hex, for every attribute in its map: those marked in p_seen plus the
-- ones an equipped item or the game mode touches.  Only attributes the client is sent (mc.attr_syncable).
create or replace function mc.attr_now(p_uuid uuid, p_held int, p_gm int, p_sprint boolean, p_seen bigint) returns table(id int, entry text) language sql stable as $$
  with eq as (
    select o.sname, o.ord as sord, i.item
      from (values ('mainhand', 36 + p_held, 0), ('offhand', 45, 1), ('feet', 8, 2), ('legs', 7, 3), ('chest', 6, 4), ('head', 5, 5)) o(sname, slot, ord)
      join mc.inventory_slot i on i.player = p_uuid and i.slot = o.slot),
  mods as (
    select r.protocol_id as attr, m.mod_id, m.amount, case m.op when 'add_value' then 0 when 'add_multiplied_base' then 1 else 2 end as op, eq.sord * 100 + m.ord as ord
      from eq join ref.item_attr m on m.item = eq.item and m.slot = eq.sname
      join ref.registry r on r.registry = 'minecraft:attribute' and r.name = m.attribute
    union all
    select 26, 'minecraft:sprinting', 0.30000001192092896, 2, -1 where p_sprint
    union all
    select 8, 'minecraft:creative_mode_block_range', 0.5, 0, -2 where p_gm = 1
    union all
    select 13, 'minecraft:creative_mode_entity_range', 2.0, 0, -2 where p_gm = 1),
  ids as (
    select a as id from generate_series(0, 39) a where (p_seen >> a) & 1 = 1
    union select attr from mods)
  select ids.id, encode(proto.varint(ids.id) || proto.f64(mc.attr_base(ids.id)) || proto.varint(count(m.attr)::int)
                        || coalesce(string_agg(proto.string(m.mod_id) || proto.f64(m.amount) || proto.i8(m.op), '\x'::bytea order by m.ord), '\x'::bytea), 'hex')
    from ids left join mods m on m.attr = ids.id
   where mc.attr_syncable(ids.id)
   group by ids.id $$;

-- the attributes every established player has (movement speed, block and entity interaction range)
create or replace function mc.attr_std_seen() returns bigint language sql immutable parallel safe as $$ select (1::bigint << 26) | (1::bigint << 8) | (1::bigint << 13) $$;

-- the update_attributes entries of a player now, for viewers who start to see it (the add_entity bundle)
create or replace function mc.pairing_attrs(p_uuid uuid, p_held int, p_gm int, p_sprint boolean, p_seen bigint) returns bytea[] language sql stable as $$
  select array_agg(decode(a.entry, 'hex') order by a.id) from mc.attr_now(p_uuid, p_held, p_gm, p_sprint, p_seen) a $$;
