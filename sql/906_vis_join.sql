-- Player visibility, part 7: the join sequence of a first-time player and of a returning one.
--
-- Recorded from the real 26.3 server (tests/e2e/vis_probe.py, scenario join), what a joiner is sent after the packets every join shares:
--   returning player   recipe_book_add (the recipes it has unlocked) is part of the entry burst; the first tick then sends set_entity_data (its own entity data), update_attributes (the
--                      attributes of its map, all dirty), update_advancements, set_health, set_experience
--   first-time player  the entry burst carries an EMPTY recipe_book_add (0001); the first tick sends set_entity_data, the recipes it unlocked by receiving the root advancements
--                      (recipe_book_add), update_advancements, set_health, set_experience; its attribute map is still empty, so update_attributes comes two ticks later
-- "First-time" is a player row that did not exist before this join.  The entity data and the attributes are generated from the player's row (what is not the default);
-- the recipe lists, the advancement update and the command tree are still the captured bytes (net.static_packet).

create or replace function mc.vis_join(p_conn int, p_uuid uuid) returns void language plpgsql as $$
declare ci jsonb; gt bigint;
begin
  if not mc.vis_on() then return; end if;
  select client_info into ci from net.conn where conn_id = p_conn;
  select game_time into gt from mc.game_state;
  update mc.player p set
      skin_parts = coalesce((ci ->> 'skin_parts')::int, 0), main_hand = coalesce((ci ->> 'main_hand')::int, 1), view_distance_req = (ci ->> 'view_distance')::int,
      sent_skin = coalesce((ci ->> 'skin_parts')::int, 0), sent_arm = coalesce((ci ->> 'main_hand')::int, 1), sent_hat = (coalesce((ci ->> 'skin_parts')::int, 0) & 64) <> 0,
      fresh_join = (p.first_seen = now()), trk_first = true, trk_ground = case when p.first_seen = now() then false else p.on_ground end,
      attr_seen = mc.attr_std_seen(), attr_gm = case when p.first_seen = now() then p.gamemode else 0 end, attr_spr = p.sprinting,
      attr_sent = case when p.first_seen = now() then null
                       else (select jsonb_object_agg(a.id::text, a.entry) from mc.attr_now(p.uuid, p.held_slot, 0, p.sprinting, mc.attr_std_seen()) a) end,     -- a returning player's entry burst already carries them, WITHOUT the creative-mode modifiers (recorded: they follow in an update_attributes a tick later: the game mode is applied after the burst)
      attr_due = case when p.first_seen = now() then gt + 3 end,
      sent_equip = mc.equip_now(p.uuid, p.held_slot), sent_held = p.held_slot, equip_dirty = false,
      wp_hidden = exists (select 1 from mc.inventory_slot i join ref.item_attr a on a.item = i.item and a.slot = 'head' and a.attribute = 'minecraft:waypoint_transmit_range' where i.player = p.uuid and i.slot = 5)
   where p.uuid = p_uuid;
  perform mc.vis_wp_join((select entity_id from mc.player where uuid = p_uuid));          -- the locator bar: connected to every transmitting player at once (sql/908)
end $$;

-- The packets of the entry burst that are not generated from the join record: the captured static ones, adapted to this player.  Used by net.play_entry_packets (sql/150).
create or replace function mc.join_static_packets(p_eid int) returns table(ord int, packet text, body bytea) language plpgsql stable as $$
declare p mc.player; attrs bytea[];
begin
  select * into p from mc.player where entity_id = p_eid;
  if not found or not mc.vis_on() then
    return query select s.ord, s.packet, case when s.entity_prefixed then proto.varint(p_eid) || s.body else s.body end from net.static_packet s where s.packet <> 'minecraft:commands';       -- (the command tree is generated: net.commands_body)
    return;
  end if;
  attrs := mc.pairing_attrs(p.uuid, p.held_slot, case when p.fresh_join then p.gamemode else 0 end, p.sprinting, mc.attr_std_seen());
  return query
    select case when p.fresh_join and s.packet = 'minecraft:recipe_book_add' then 235 else s.ord end, s.packet, case when s.entity_prefixed then proto.varint(p_eid) || s.body else s.body end
      from net.static_packet s where s.packet not in ('minecraft:set_entity_data', 'minecraft:update_attributes', 'minecraft:commands')
    union all select 90, 'minecraft:recipe_book_add', '\x0001'::bytea where p.fresh_join
    union all select w.ord, w.packet, w.body from mc.wp_join_packets(p_eid) w
    union all select 230, 'minecraft:set_entity_data',
                     proto.varint(p_eid) || mc.ed_entries(mc.ed_flags(p.shift, p.sprinting, p.gamemode), p.pose, case when p.use_slot is not null then 1 else 0 end, p.health, p.main_hand, p.skin_parts, p.xp_score, mc.ed_nondefault_mask(p))
    union all select 240, 'minecraft:update_attributes', proto.varint(p_eid) || proto.varint(cardinality(attrs)) || proto.cat(attrs) where not p.fresh_join and attrs is not null;
end $$;

-- A respawn creates a new entity with the old id: the tracker starts again at this tick (the viewers get a pairing bundle from the visibility pass and a second set_entity_data
-- in the first tick), and the player is a returning one as far as its attributes are concerned.
create or replace function mc.vis_respawn(p_uuid uuid, p_cur bigint) returns void language plpgsql as $$
begin
  if not mc.vis_on() then return; end if;
  update mc.player p set
      shift = false, flying = (p.gamemode = 3), pose = 0, sent_flags = mc.ed_flags(false, false, p.gamemode), sent_pose = 0, sent_skin = p.skin_parts, sent_arm = p.main_hand,
      trk_start = p_cur, trk_first = true, fresh_join = false, base_x = p.x, base_y = p.y, base_z = p.z, sent_yb = mc.angle_byte(p.yaw), sent_pb = mc.angle_byte(p.pitch), sent_hb = mc.angle_byte(p.yaw),
      head_yaw = p.yaw, trk_sync = -2, trk_ground = true, vis_x = p.x, vis_z = p.z, tp_ground_tick = null,
      attr_seen = mc.attr_std_seen(), attr_gm = p.gamemode, attr_spr = false, attr_due = null,
      attr_sent = (select jsonb_object_agg(a.id::text, a.entry) from mc.attr_now(p.uuid, p.held_slot, p.gamemode, false, mc.attr_std_seen()) a),
      sent_equip = mc.equip_now(p.uuid, p.held_slot), sent_held = p.held_slot, equip_dirty = false
   where p.uuid = p_uuid;
end $$;
