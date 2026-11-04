-- Player visibility, part 6: the per-tick step.  mc.tick_core (sql/837) calls mc.vis_step(tick) once, between the visibility refresh and the survival entity phase.
-- Vanilla's tick, as far as other players are concerned:
--   network phase      packets are applied the moment they arrive: movement, player_input, punch (swing_animation goes out at once), client_information (hat flag out at once)
--   tracker pass       ChunkMap.tick: pairing (updatePlayers: add_entity bundles, sql/903), then ServerEntity.sendChanges of every entity: the dirty entity data (one set_entity_data
--                      with every changed entry), the movement
--   entity phase       Entity.tick: the pose is recomputed (so a pose reaches the viewers one tick after the flag that caused it), equipment is compared and set_equipment sent,
--                      attributes are compared and update_attributes sent (an equipment change shows in the attributes one tick later), PlayerList.tick: the latency broadcast
-- mc.vis_step does the packet-phase leftovers (sql/904), the tracker's entity-data flush (mc.survival_tracker, sql/833, which also carries health, item use and score) and the entity phase.

create or replace function mc.vis_entity_phase(p_cur bigint) returns void language plpgsql as $$
declare e_eq int[]; d_eq bytea[]; e_at int[]; d_at bytea[]; n int;
begin
  -- a player moved by the server (/tp) was not on the ground for a tick (mc.sync_entity_position); the entity phase of the next tick finds the ground again
  update mc.player set on_ground = true, tp_ground_tick = null where conn_id is not null and tp_ground_tick is not null and tp_ground_tick <= p_cur;
  -- the pose: crouching while the shift key is down and the player is not flying (Player.updatePlayerPose)
  update mc.player p set pose = case when p.shift and not p.flying then 5 else 0 end
   where p.conn_id is not null and p.pose is distinct from (case when p.shift and not p.flying then 5 else 0 end);

  -- equipment: the six visible slots compared with what the viewers were last sent; only the changed slots are broadcast (to the viewers, not to the player)
  if exists (select 1 from mc.player p where p.conn_id is not null and (p.equip_dirty or p.sent_held is distinct from p.held_slot)) then
    with c as (
      select p.entity_id as eid, p.uuid, p.held_slot, p.sent_equip, mc.equip_now(p.uuid, p.held_slot) as cur
        from mc.player p where p.conn_id is not null and (p.equip_dirty or p.sent_held is distinct from p.held_slot)),
    d as (
      select c.*, (select array_agg((o - 1)::int order by o) from unnest(c.cur, coalesce(c.sent_equip, c.cur)) with ordinality t(a, b, o) where a is distinct from b) as slots,
             (select array_agg(a order by o) from unnest(c.cur, coalesce(c.sent_equip, c.cur)) with ordinality t(a, b, o) where a is distinct from b) as stacks
        from c),
    u as (
      update mc.player p set sent_equip = d.cur, sent_held = d.held_slot, equip_dirty = false, attr_due = case when d.slots is not null then p_cur + 1 else p.attr_due end,
             wp_hidden = exists (select 1 from mc.inventory_slot i join ref.item_attr a on a.item = i.item and a.slot = 'head' and a.attribute = 'minecraft:waypoint_transmit_range' where i.player = d.uuid and i.slot = 5)     -- a head that hides the wearer from the locator bar
        from d where p.entity_id = d.eid returning 1)
    select array_agg(d.eid order by d.eid), array_agg(mc.pkt_equipment(d.eid, d.slots, d.stacks) order by d.eid) into e_eq, d_eq from d where d.slots is not null;
    if e_eq is not null then perform mc.send_players_and_viewers(e_eq, d_eq, false); end if;
  end if;

  -- attributes: a game mode change is picked up here and shows one tick later; sprinting shows at once; an equipment change was scheduled for the tick after it
  if exists (select 1 from mc.player p where p.conn_id is not null and (p.attr_gm is distinct from p.gamemode or p.attr_spr is distinct from p.sprinting or (p.attr_due is not null and p.attr_due <= p_cur))) then
    update mc.player p set attr_gm = p.gamemode, attr_due = coalesce(p.attr_due, p_cur + 1)
     where p.conn_id is not null and p.attr_gm is distinct from p.gamemode;
    with c as (
      select p.entity_id as eid, p.uuid, p.attr_sent, p.attr_seen, p.held_slot, p.gamemode, p.sprinting
        from mc.player p where p.conn_id is not null and (p.attr_spr is distinct from p.sprinting or (p.attr_due is not null and p.attr_due <= p_cur))),
    n as (select c.eid, c.attr_sent, c.attr_seen, a.id, a.entry from c cross join lateral mc.attr_now(c.uuid, c.held_slot, c.gamemode, c.sprinting, c.attr_seen) a),
    ch as (select n.eid, n.id, n.entry from n where (n.attr_sent ->> n.id::text) is distinct from n.entry),
    agg as (select ch.eid, array_agg(decode(ch.entry, 'hex') order by ch.id) as ents, jsonb_object_agg(ch.id::text, ch.entry) as upd,
                   bit_or(1::bigint << ch.id) as seen_bits from ch group by ch.eid),
    u as (
      update mc.player p set attr_sent = coalesce(p.attr_sent, '{}'::jsonb) || coalesce(agg.upd, '{}'::jsonb), attr_seen = p.attr_seen | coalesce(agg.seen_bits, 0),
             attr_spr = p.sprinting, attr_due = case when p.attr_due <= p_cur then null else p.attr_due end, fresh_join = case when p.attr_due <= p_cur then false else p.fresh_join end
        from c left join agg on agg.eid = c.eid where p.entity_id = c.eid returning 1)
    select array_agg(agg.eid order by agg.eid), array_agg(mc.pkt_update_attributes(agg.eid, agg.ents) order by agg.eid) into e_at, d_at from agg;
    if e_at is not null then perform mc.send_players_and_viewers(e_at, d_at); end if;
  end if;

  -- PlayerList.tick: every 601 ticks the latency of everybody goes to everybody
  if p_cur % 601 = 0 then
    insert into mc.play_out (conn_id, data)
    select o.conn_id, l.d from mc.player o, (select mc.pkt_player_info_latencies(array_agg(uuid order by entity_id), array_agg(latency_ms order by entity_id)) as d from mc.player where conn_id is not null) l
     where o.conn_id is not null and l.d is not null order by o.entity_id;
  end if;
end $$;

-- a player row that went online without mc.vis_join (the layer was switched on while it played, a test or a tool inserted it with a connection id): the tracker starts for it now
create or replace function mc.vis_init_rows(p_cur bigint) returns void language sql as $$
  update mc.player set trk_start = p_cur, base_x = x, base_y = y, base_z = z, sent_yb = mc.angle_byte(yaw), sent_pb = mc.angle_byte(pitch), sent_hb = mc.angle_byte(yaw), head_yaw = yaw,
         trk_sync = -2, trk_ground = on_ground, vis_x = x, vis_z = z, sent_equip = coalesce(sent_equip, mc.equip_now(uuid, held_slot)), sent_held = coalesce(sent_held, held_slot), equip_dirty = false,
         attr_seen = case when attr_seen = 0 then mc.attr_std_seen() else attr_seen end, attr_gm = coalesce(attr_gm, gamemode), attr_spr = coalesce(attr_spr, sprinting)
   where conn_id is not null and trk_start is null $$;

create or replace function mc.vis_step(p_cur bigint) returns void language plpgsql as $$
begin
  if not mc.vis_on() then return; end if;
  perform mc.vis_init_rows(p_cur);
  perform mc.vis_input(p_cur);                      -- network phase leftovers (shift key, swings, client information, abilities)
  perform mc.vis_chat_spam(p_cur);                  -- chat and command rate limits (sql/910)
  perform mc.survival_tracker(p_cur, null);         -- tracker pass: the dirty entity data of every player in one set_entity_data
  perform mc.vis_move(p_cur);                       --   ... and the movement (sql/907)
  perform mc.vis_first_tick(p_cur);                 -- a new entity's first tick: what became dirty while it was created
  perform mc.vis_wp_pass(p_cur, 2);                 -- entity phase: the locator bar follows crouching, the game mode, a new player
  perform mc.vis_entity_phase(p_cur);               --   ... pose, equipment, attributes, latency
  perform mc.vis_head(p_cur);                       --   ... and the head rotation follows the yaw
end $$;
