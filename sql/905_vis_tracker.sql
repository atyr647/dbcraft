-- Player visibility, part 6: the per-tick step.  mc.tick_core (sql/837) calls mc.vis_step(tick) once, between the visibility refresh and the survival entity phase.
-- Vanilla's tick, as far as other players are concerned:
--   network phase      packets are applied the moment they arrive: movement, player_input, punch (swing_animation goes out at once), client_information (hat flag out at once)
--   tracker pass       ChunkMap.tick: pairing (updatePlayers: add_entity bundles, sql/903), then ServerEntity.sendChanges of every entity: the dirty entity data (one set_entity_data
--                      with every changed entry), the movement
--   entity phase       Entity.tick: the pose is recomputed (so a pose reaches the viewers one tick after the flag that caused it), equipment is compared and set_equipment sent,
--                      attributes are compared and update_attributes sent (an equipment change shows in the attributes one tick later), PlayerList.tick: the latency broadcast
-- mc.vis_step does the packet-phase leftovers (sql/904), the tracker's entity-data flush (mc.survival_tracker, sql/833, which also carries health, item use and score) and the entity phase.

drop function if exists mc.vis_entity_phase(bigint);
create or replace function mc.vis_entity_phase(p_cur bigint, w mc.vis_work default null) returns void language plpgsql as $$
declare e_eq int[]; d_eq bytea[]; e_at int[]; d_at bytea[]; n int;
begin
  if w is null then w := mc.vis_find(p_cur); end if;
  -- a player moved by the server (/tp) was not on the ground for a tick (mc.sync_entity_position); the entity phase of the next tick finds the ground again
  if w.tpg then
    update mc.player set on_ground = true, tp_ground_tick = null, vis_wake = p_cur + 4 where conn_id is not null and tp_ground_tick is not null and tp_ground_tick <= p_cur;
  end if;
  -- the pose: crouching while the shift key is down and the player is not flying (Player.updatePlayerPose)
  if w.pose then
    update mc.player p set pose = case when p.shift and not p.flying then 5 else 0 end
     where p.conn_id is not null and p.pose is distinct from (case when p.shift and not p.flying then 5 else 0 end);
  end if;

  -- equipment: the six visible slots compared with what the viewers were last sent; only the changed slots are broadcast (to the viewers, not to the player)
  if w.eq then
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
  if w.att then
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

-- ONE scan of the online players says who has work this tick, for every step of the tracker (a scan of the wide mc.player costs about a millisecond at 500 players, and the steps used to
-- scan it one after the other, nine times, to find out that nothing had changed).  Every predicate below is the WHERE condition of the step it gates, evaluated on the same columns.
--   dirty   pairs to re-evaluate (sql/909)                       mvn     how many players the movement step looks at (it finds them itself with the same test): moved in the last two ticks (the body runs on even ticks, the
--   ed      an unsent entity data change (mc.survival_tracker)           head rotation follows a tick later), woken by an event (vis_wake: a join, a teleport, a game mode
--   eq / att / pose / tpg / first  the steps of the entity phase         change), the 60-tick refresh and the sync after 400 runs
--           (a move at this tick or the one before changes what a body sends; a move two ticks ago only through the head, which follows the yaw a tick later)
--   wp1     a player moved or its block position differs from the locator bar's last pass   wp2  a transmit state changed   recheck  a game mode change waits for a movement packet
-- The answer is also kept for the rest of the tick (a transaction-local setting): mc.refresh_visibility computes it, mc.vis_step reuses it.
create or replace function mc.vis_find(p_cur bigint) returns mc.vis_work language plpgsql as $$
declare w mc.vis_work; vison boolean := mc.vis_on(); all_mv boolean := coalesce(current_setting('dbcraft.vis_scan_all', true), '') = 'on';       -- (tests: look at everybody)
begin
  w.cur := p_cur;
  select count(*)::int,
         array_agg(x.eid) filter (where x.dirty),
         count(*) filter (where x.mv)::int,
         array_agg(x.eid) filter (where x.ed),
         coalesce(bool_or(x.eq), false), coalesce(bool_or(x.att), false), coalesce(bool_or(x.pose), false), coalesce(bool_or(x.tpg), false), coalesce(bool_or(x.first), false),
         coalesce(bool_or(x.wp1), false), coalesce(bool_or(x.wp2), false), coalesce(bool_or(x.recheck), false)
    into w.n, w.dirty, w.mvn, w.ed, w.eq, w.att, w.pose, w.tpg, w.first, w.wp1, w.wp2, w.recheck
    from (
      select p.entity_id as eid, p.vis_dirty as dirty,
             (p.trk_start is not null and p.trk_start <= p_cur and (p_cur - p.trk_start) % 2 = 0
              and (all_mv or p.last_move_tick >= p_cur - 1 or (p.last_move_tick = p_cur - 2 and p.yaw_prev is distinct from p.yaw)
                   or p.vis_wake >= p_cur or (p_cur - p.trk_start) % 60 = 0 or p_cur - p.trk_start - p.trk_sync >= 802)) as mv,
             (p.sent_health is null or p.sent_eh is distinct from p.health or p.sent_using is distinct from (p.use_slot is not null) or p.sent_score is distinct from p.xp_score
              or (vison and (p.sent_flags is distinct from mc.ed_flags(p.shift, p.sprinting, p.gamemode) or p.sent_pose is distinct from p.pose
                             or p.sent_arm is distinct from p.main_hand or p.sent_skin is distinct from p.skin_parts))) as ed,
             (p.equip_dirty or p.sent_held is distinct from p.held_slot) as eq,
             (p.attr_gm is distinct from p.gamemode or p.attr_spr is distinct from p.sprinting or (p.attr_due is not null and p.attr_due <= p_cur)) as att,
             (p.pose is distinct from (case when p.shift and not p.flying then 5 else 0 end)) as pose,
             (p.tp_ground_tick is not null and p.tp_ground_tick <= p_cur) as tpg,
             p.trk_first as first,
             (p.last_move_tick = p_cur or p.wp_bx is distinct from floor(p.x)::int or p.wp_by is distinct from floor(p.y)::int or p.wp_bz is distinct from floor(p.z)::int
              or p.wp_cx is distinct from p.chunk_x or p.wp_cz is distinct from p.chunk_z) as wp1,
             (p.wp_state is distinct from ((case when p.pose <> 5 and not p.wp_hidden then 1 else 0 end) | (case when p.gamemode = 3 then 2 else 0 end))) as wp2,
             (p.vis_recheck and exists (select 1 from mc.player m where m.last_move_tick = p_cur and m.conn_id is not null)) as recheck
        from mc.player p where p.conn_id is not null) x;
  select count(*)::int into w.nvt from mc.vtrk;
  perform set_config('dbcraft.vis_work', w::text, true);
  return w;
end $$;

-- the answer computed earlier in this tick (by mc.refresh_visibility), or a new one
create or replace function mc.vis_work_now(p_cur bigint) returns mc.vis_work language plpgsql as $$
declare w mc.vis_work; s text := current_setting('dbcraft.vis_work', true);
begin
  if s is not null and s <> '' then
    w := s::mc.vis_work;
    if w.cur = p_cur then return w; end if;
  end if;
  return mc.vis_find(p_cur);
end $$;

create or replace function mc.vis_step(p_cur bigint) returns void language plpgsql as $$
declare w mc.vis_work;
begin
  if not mc.vis_on() then return; end if;
  w := mc.vis_work_now(p_cur);
  if w.n > coalesce(w.nvt, 0) then                  -- an online player without its tracker row (the unlogged table was emptied by a crash, a row inserted by a tool that bypassed the triggers)
    perform mc.vis_init_missing(p_cur);
    w := mc.vis_find(p_cur);
  end if;
  if mc.vis_input(p_cur) then w := mc.vis_find(p_cur); end if;      -- network phase leftovers (shift key, swings, client information, abilities); something changed: look again
  perform mc.vis_chat_spam(p_cur);                  -- chat and command rate limits (sql/910)
  if w.ed is not null then perform mc.survival_tracker(p_cur, w.ed); end if;      -- tracker pass: the dirty entity data of the players that have some, in one set_entity_data each
  if w.mvn > 0 then perform mc.vis_move(p_cur); end if;      --   ... and the movement (sql/907)
  if w.first then perform mc.vis_first_tick(p_cur); end if;      -- a new entity's first tick: what became dirty while it was created
  if w.wp2 then perform mc.vis_wp_pass(p_cur, 2, w.n); end if;   -- entity phase: the locator bar follows crouching, the game mode, a new player
  perform mc.vis_entity_phase(p_cur, w);            --   ... pose, equipment, attributes, latency
end $$;

-- a player row that went online without the triggers: the tracker starts for it now (a tracker row, and the sent_* state of what it has been told counts as the current one)
create or replace function mc.vis_init_missing(p_cur bigint) returns void language plpgsql as $$
begin
  insert into mc.vtrk (entity_id, base_x, base_y, base_z, sent_yb, sent_pb, sent_hb)
  select p.entity_id, p.x, p.y, p.z, mc.angle_byte(p.yaw), mc.angle_byte(p.pitch), mc.angle_byte(p.yaw)
    from mc.player p where p.conn_id is not null and p.entity_id is not null and not exists (select 1 from mc.vtrk v where v.entity_id = p.entity_id)
  on conflict (entity_id) do nothing;
  update mc.player p set trk_start = coalesce(p.trk_start, p_cur), vis_x = coalesce(p.vis_x, p.x), vis_z = coalesce(p.vis_z, p.z), vis_wake = p_cur + 8,
         sent_equip = coalesce(p.sent_equip, mc.equip_now(p.uuid, p.held_slot)), sent_held = coalesce(p.sent_held, p.held_slot), equip_dirty = false,
         attr_seen = case when p.attr_seen = 0 then mc.attr_std_seen() else p.attr_seen end, attr_gm = coalesce(p.attr_gm, p.gamemode), attr_spr = coalesce(p.attr_spr, p.sprinting),
         trk_ground = coalesce(p.trk_ground, p.on_ground)
   where p.conn_id is not null and p.trk_start is null;
end $$;
