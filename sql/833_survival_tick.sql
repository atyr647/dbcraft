-- Survival core, part 4: the per-tick steps.  mc.tick_core (sql/836) calls them in vanilla's order:
--
--   survival_pre      before movement:  player_command (sprinting) and a snapshot of the survival players' positions
--   survival_moves    after movement:   fall damage (+ the landing particles), jump and sprint exhaustion          (ServerGamePacketListenerImpl.handlePlayerPositionChange)
--   ... commands, respawn requests, use_item (sql/834, 835) ...
--   survival_tracker  the health, "using an item" and score changes of the entity data, to the player and everyone who sees them   (ServerEntity.sendChanges)
--   survival_void     below the world: 4 damage a tick                                                              (Entity.checkBelowWorld)
--   survival_food     FoodData.tick: exhaustion, saturation, natural regeneration, starvation; peaceful regeneration (ServerPlayer.tickRegeneration)
--   survival_sync     set_health and set_experience when something changed                                          (ServerPlayer.doTick)
-- In vanilla's tick the tracker pass runs BEFORE the entities tick, so damage that arrives with the player's own packets (fall) reaches the viewers' entity data in the
-- same tick, damage from the entity tick (void, starvation, regeneration) one tick later; this order reproduces the timestamps of the recorded runs.
-- Every step finds its players with one cheap scan or comparison, so a server where nobody is hurt, hungry or falling pays almost nothing.

------------------------------------------------------------------------------------------------ pre: sprinting + snapshot
drop type if exists mc.surv_snap cascade;
create type mc.surv_snap as (eid int[], x float8[], y float8[], z float8[], og boolean[], kinds int[]);      -- kinds: the packet ids of ours present in this tick's input (player_command, client_command, use_item, player_action)

create or replace function mc.survival_pre() returns mc.surv_snap language plpgsql as $$
declare i_cmd int := mc.sid('player_command'); i_cc int := mc.sid('client_command'); i_use int := mc.sid('use_item'); i_act int := mc.sid('player_action'); s mc.surv_snap;
begin
  -- one look at the tick's input for everything below (the queue is scanned once, not once per question)
  select coalesce(array_agg(distinct packet_id) filter (where packet_id in (i_cmd, i_cc, i_use, i_act)), '{}') into s.kinds from mc.play_in_work;
  -- player_command: VarInt entity id | VarInt action (1 start sprinting, 2 stop sprinting) | VarInt data.  The last one of the tick wins.
  if i_cmd = any (s.kinds) then
    update mc.player p set sprinting = (c.act = 1)
      from (select distinct on (m.conn_id) m.conn_id, proto.varint_safe(m.body, (select nxt from proto.varint_read(m.body, 0))) as act
              from mc.play_in_work m where m.packet_id = i_cmd and length(m.body) >= 2 order by m.conn_id, m.seq desc) c
     where p.conn_id = c.conn_id and c.act in (1, 2) and p.sprinting <> (c.act = 1);
    delete from mc.play_in_work where packet_id = i_cmd;
  end if;
  select array_agg(entity_id), array_agg(x), array_agg(y), array_agg(z), array_agg(on_ground) into s.eid, s.x, s.y, s.z, s.og
    from mc.player where conn_id is not null and gamemode in (0, 2) and not dead;
  return s;
end $$;

------------------------------------------------------------------------------------------------ moves: fall damage, jump and sprint exhaustion
-- Per move (one position packet per tick at most): Entity.checkFallDamage: fallDistance -= (float) dy while falling; on the ground: a fall of more than 3 blocks hurts
-- floor(fallDistance + 1e-6 - 3) (Block.fallOn: x0.2 hay, x0.5 beds, x0 slime) and the distance is reset; moving up resets it too; a teleport resets it; creative and
-- spectator (may fly) take no fall damage.  The landing puff of particles (LivingEntity.checkFallDamage) is computed from the distance BEFORE this move's dy.
-- Jumping (on the ground, leaving it, going up) costs 0.05 exhaustion (0.2 sprinting); sprinting on the ground costs 0.1 per metre (rounded to centimetres).
-- NOT modelled: water (a fall into water is not recognised), climbables, elytra, slow falling / jump boost effects.
create or replace function mc.survival_moves(p_cur bigint, s mc.surv_snap) returns void language plpgsql
set enable_nestloop = off as $$        -- (a hash join of the 500-row snapshot with the table: 0.5 ms instead of 0.8 ms of index probes, measured)
declare fe int[]; fa real[]; pe int[]; pf float8[];
begin
  if s.eid is null and not exists (select 1 from mc.player where conn_id is not null and not dead and (fall_distance <> 0 or fall_tp <> teleport_id)) then return; end if;
  with sn as (select * from unnest(s.eid, s.x, s.y, s.z, s.og) as t(eid, ox, oy, oz, oog)),
  c as (
    select p.entity_id as eid, p.gamemode, p.x, p.y, p.z, p.on_ground as nog, p.teleport_id, p.sprinting, sn.oog,
           (p.y - sn.oy) as dy, sqrt((p.x - sn.ox) ^ 2 + (p.z - sn.oz) ^ 2) as dh,
           case when p.teleport_id <> p.fall_tp or p.gamemode in (1, 3) then 0 else p.fall_distance end as fd0
      from sn join mc.player p on p.entity_id = sn.eid
     where p.conn_id is not null and not p.dead
       and (p.y <> sn.oy or p.on_ground <> sn.oog or p.fall_distance <> 0 or p.teleport_id <> p.fall_tp or (p.sprinting and (p.x <> sn.ox or p.z <> sn.oz)))),
  f as (
    select c.*, case when c.dy < 0 then c.fd0 - (c.dy::real)::float8 else c.fd0 end as fd1 from c),
  g as (
    select f.*, (f.nog and f.fd1 > 0) as landed,
           (f.nog and f.fd0 > 0 and f.gamemode not in (1, 3)) as puff,
           -- exhaustion: jump (on the ground, leaving it, going up) and sprinting on the ground
           case when f.gamemode in (1, 3) then 0::real
                else (case when f.oog and not f.nog and f.dy > 0 then case when f.sprinting then 0.2::real else 0.05::real end else 0::real end)
                   + (case when f.nog and f.sprinting then 0.1::real * floor(f.dh::real * 100::real + 0.5::real)::int::real * 0.01::real else 0::real end) end as exh
      from f),
  u as (
    update mc.player p set
        fall_distance = case when g.landed and g.fd1 + 1e-6 - 3.0 >= 1.0 then g.fd1 when g.nog or g.dy > 0 then 0 else g.fd1 end,
        fall_tp = g.teleport_id,
        exhaustion = least(p.exhaustion + g.exh, 40::real)
      from g where p.entity_id = g.eid and (p.fall_distance, p.fall_tp, p.exhaustion) is distinct from
           (case when g.landed and g.fd1 + 1e-6 - 3.0 >= 1.0 then g.fd1 when g.nog or g.dy > 0 then 0 else g.fd1 end, g.teleport_id, least(p.exhaustion + g.exh, 40::real))
    returning p.entity_id as eid, g.landed, g.puff, g.fd0, g.fd1, g.x, g.y, g.z)
  select coalesce(array_agg(eid order by eid) filter (where landed and fd1 + 1e-6 - 3.0 >= 1.0), '{}'),
         coalesce(array_agg(floor((fd1 + 1e-6 - 3.0))::real order by eid) filter (where landed and fd1 + 1e-6 - 3.0 >= 1.0), '{}'),
         coalesce(array_agg(eid order by eid) filter (where puff and floor(fd0 + 1e-6 - 3.0) > 0), '{}'),
         coalesce(array_agg(fd0 order by eid) filter (where puff and floor(fd0 + 1e-6 - 3.0) > 0), '{}')
    into fe, fa, pe, pf from u;
  if cardinality(fe) = 0 and cardinality(pe) = 0 then return; end if;
  -- Block.fallOn: hay and honey blocks take 0.2 of the damage, slime blocks none (a sneaking player would take it all: sneaking is not tracked)
  if cardinality(fe) > 0 then
    select array_agg(q.eid order by q.eid), array_agg(q.dmg order by q.eid) into fe, fa
      from (select p.entity_id as eid,
                   floor((p.fall_distance + 1e-6 - 3.0) * case split_part(b.blk, '[', 1) when 'minecraft:hay_block' then 0.2::real::float8 when 'minecraft:honey_block' then 0.2::real::float8
                                                                 when 'minecraft:slime_block' then 0 else 1 end)::real as dmg
              from mc.player p
              cross join lateral (select mc.get_block('minecraft:overworld', floor(p.x)::int, floor(p.y - 0.2)::int, floor(p.z)::int) as blk) b
             where p.entity_id = any (fe)) q where q.dmg > 0;
    fe := coalesce(fe, '{}'); fa := coalesce(fa, '{}');
  end if;
  -- the landing particles: block particles of the block under the feet, to everyone within 32 blocks; count = (int)(150 * min(0.2 + power / 15, 2.5))
  if cardinality(pe) > 0 then
    insert into mc.play_out (conn_id, data)
    select o.conn_id, string_agg(q.pkt, '\x'::bytea order by q.eid)
      from (select p.entity_id as eid, p.x, p.y, p.z,
                   mc.pkt_particles_block(p.x, p.y, p.z, mc.block_state_id(b.blk), (150 * least(0.2 + floor(t.fd0 + 1e-6 - 3.0)::float8 / 15, 2.5))::int) as pkt
              from unnest(pe, pf) as t(eid, fd0) join mc.player p on p.entity_id = t.eid
              cross join lateral (select mc.get_block('minecraft:overworld', floor(p.x)::int, floor(p.y - 0.2)::int, floor(p.z)::int) as blk) b
             where b.blk is not null and b.blk <> 'minecraft:air') q
      join mc.player o on o.conn_id is not null
           and (floor(o.x) + 0.5 - q.x) ^ 2 + (floor(o.y) + 0.5 - q.y) ^ 2 + (floor(o.z) + 0.5 - q.z) ^ 2 < 1024
     group by o.conn_id order by o.conn_id;
  end if;
  if cardinality(fe) > 0 then
    perform mc.hurt(fe, fa, 'fall', p_cur);
    update mc.player set fall_distance = 0 where entity_id = any (fe);
  end if;
end $$;

------------------------------------------------------------------------------------------------ the void
drop function if exists mc.survival_void(bigint); drop function if exists mc.survival_tracker(bigint); drop function if exists mc.survival_food(bigint); drop function if exists mc.survival_sync(bigint);
create or replace function mc.survival_void(p_cur bigint, p_ids int[] default null) returns void language plpgsql as $$
declare e int[];
begin
  select coalesce(array_agg(entity_id), '{}') into e from mc.player where conn_id is not null and not dead and y < -128 and (p_ids is null or entity_id = any (p_ids));       -- Level.getMinY() - 64 (the overworld's min_y is -64)
  if cardinality(e) > 0 then perform mc.hurt(e, array_fill(4::real, array[cardinality(e)]), 'out_of_world', p_cur); end if;
end $$;

------------------------------------------------------------------------------------------------ tracker: entity data
create or replace function mc.survival_tracker(p_cur bigint, p_ids int[] default null) returns void language plpgsql as $$
declare e int[]; d bytea[]; vison boolean := mc.vis_on();
begin
  -- a player row that went online without the join trigger (inserted with a connection id by a test or a tool) has nothing "sent" yet: its current values count as sent
  update mc.player set sent_health = health, sent_food = food, sent_sat_zero = (saturation = 0), sent_eh = health, sent_xp_total = xp_total, sent_score = xp_score, sent_using = false,
         sent_flags = mc.ed_flags(shift, sprinting, gamemode), sent_pose = pose, sent_skin = skin_parts, sent_arm = main_hand,        -- (sql/900: the other entity data other players see)
         join_tick = coalesce(join_tick, p_cur)
   where conn_id is not null and sent_health is null and (p_ids is null or entity_id = any (p_ids));
  -- one set_entity_data per player with everything that changed, entries in index order: 0 flags, 6 pose, 8 living flags, 9 health, 15 main arm, 16 skin layers, 18 score
  -- (the flags, pose, arm and skin entries only with dbcraft.vanilla-tracker: sql/900)
  select array_agg(q.eid order by q.eid), array_agg(q.pkt order by q.eid) into e, d
    from (select p.entity_id as eid,
                 mc.pkt_entity_data(p.entity_id, mc.ed_entries(mc.ed_flags(p.shift, p.sprinting, p.gamemode), p.pose, case when p.use_slot is not null then 1 else 0 end, p.health, p.main_hand, p.skin_parts, p.xp_score,
                     (case when vison and p.sent_flags is distinct from mc.ed_flags(p.shift, p.sprinting, p.gamemode) then 1 else 0 end)
                   | (case when vison and p.sent_pose is distinct from p.pose then 2 else 0 end)
                   | (case when p.sent_using is distinct from (p.use_slot is not null) then 4 else 0 end)
                   | (case when p.sent_eh is distinct from p.health then 8 else 0 end)
                   | (case when vison and p.sent_arm is distinct from p.main_hand then 16 else 0 end)
                   | (case when vison and p.sent_skin is distinct from p.skin_parts then 32 else 0 end)
                   | (case when p.sent_score is distinct from p.xp_score then 64 else 0 end))) as pkt
            from mc.player p
           where p.conn_id is not null and (p_ids is null or p.entity_id = any (p_ids))
             and (p.sent_eh is distinct from p.health or p.sent_using is distinct from (p.use_slot is not null) or p.sent_score is distinct from p.xp_score
                  or (vison and (p.sent_flags is distinct from mc.ed_flags(p.shift, p.sprinting, p.gamemode) or p.sent_pose is distinct from p.pose
                                 or p.sent_arm is distinct from p.main_hand or p.sent_skin is distinct from p.skin_parts)))) q;
  if e is null then return; end if;
  perform mc.send_players_and_viewers(e, d);
  update mc.player p set sent_eh = p.health, sent_using = (p.use_slot is not null), sent_score = p.xp_score,
         sent_flags = case when vison then mc.ed_flags(p.shift, p.sprinting, p.gamemode) else p.sent_flags end, sent_pose = case when vison then p.pose else p.sent_pose end,
         sent_arm = case when vison then p.main_hand else p.sent_arm end, sent_skin = case when vison then p.skin_parts else p.sent_skin end
   where p.entity_id = any (e);
  -- the stack that was eaten is re-sent one tick after the use completed (the menu's broadcastChanges at the start of the next tick)
  insert into mc.play_out (conn_id, data)
  select p.conn_id, string_agg(mc.pkt_container_set_slot(p.inv_state, p.pend_slot, i.item, coalesce(i.count, 0)), '\x'::bytea)
    from mc.player p left join mc.inventory_slot i on i.player = p.uuid and i.slot = p.pend_slot
   where p.entity_id = any (e) and p.pend_slot is not null group by p.conn_id;
  update mc.player set pend_slot = null where entity_id = any (e) and pend_slot is not null;
end $$;

------------------------------------------------------------------------------------------------ food: FoodData.tick and peaceful regeneration
create or replace function mc.survival_food(p_cur bigint, p_ids int[] default null) returns void language plpgsql as $$
declare diff int := mc.difficulty(); regen boolean := mc.rule_bool('natural_health_regeneration', true); se int[];
begin
  -- candidates: exhaustion to drain, a player who is hurt (health in (0, 20)), a starving player, or a running timer; everybody else has nothing to do this tick
  with c as (
    select p.entity_id as eid, p.health, p.food, p.saturation, p.exhaustion, p.food_timer,
           (p.health > 0 and p.health < 20) as hurt
      from mc.player p
     where p.conn_id is not null and (p_ids is null or p.entity_id = any (p_ids)) and (p.exhaustion > 4 or (p.health > 0 and p.health < 20) or p.food <= 0 or p.food_timer <> 0)),     -- (a dead player's FoodData still ticks: the exhaustion drains, as the recorded death shows)
  -- 1. exhaustion above 4 drains saturation first, then food (never on peaceful)
  d as (
    select c.*, (c.exhaustion > 4) as drain,
           case when c.exhaustion > 4 then c.exhaustion - 4 else c.exhaustion end as ex1,
           case when c.exhaustion > 4 and c.saturation > 0 then greatest(c.saturation - 1, 0) else c.saturation end as sat1,
           case when c.exhaustion > 4 and not c.saturation > 0 and diff <> 0 then greatest(c.food - 1, 0) else c.food end as food1
      from c),
  -- 2. which branch applies with the drained values
  b as (
    select d.*, case when regen and d.sat1 > 0 and d.hurt and d.food1 >= 20 then 1
                     when regen and d.food1 >= 18 and d.hurt then 2
                     when d.food1 <= 0 then 3 else 0 end as br
      from d),
  t as (
    select b.*, case when b.br = 0 then 0 else b.food_timer + 1 end as tm from b),
  r as (
    select t.*, case when t.br = 1 and t.tm >= 10 then 1 when t.br = 2 and t.tm >= 80 then 2 when t.br = 3 and t.tm >= 80 then 3 else 0 end as act from t),
  u as (
    update mc.player p set
        exhaustion = case r.act when 1 then least(r.ex1 + least(r.sat1, 6::real), 40::real) when 2 then least(r.ex1 + 6::real, 40::real) else r.ex1 end,
        saturation = r.sat1, food = r.food1,
        health = case r.act when 1 then least(r.health + least(r.sat1, 6::real) / 6::real, 20::real) when 2 then least(r.health + 1::real, 20::real) else r.health end,
        food_timer = case when r.act <> 0 then 0 else r.tm end
      from r where p.entity_id = r.eid
       and (p.exhaustion, p.saturation, p.food, p.health, p.food_timer) is distinct from
           (case r.act when 1 then least(r.ex1 + least(r.sat1, 6::real), 40::real) when 2 then least(r.ex1 + 6::real, 40::real) else r.ex1 end, r.sat1, r.food1,
            case r.act when 1 then least(r.health + least(r.sat1, 6::real) / 6::real, 20::real) when 2 then least(r.health + 1::real, 20::real) else r.health end, case when r.act <> 0 then 0 else r.tm end)
    returning p.entity_id as eid, r.act, r.health as oh)
  select array_agg(eid) into se from u where act = 3 and (oh > 10 or diff = 3 or (oh > 1 and diff = 2));
  -- starvation (FoodData.tick): at food 0, every 80 ticks, 1 damage if health > 10, or on hard, or on normal while above 1 health; through the normal pipeline
  if se is not null then perform mc.hurt(se, array_fill(1::real, array[cardinality(se)]), 'starve', p_cur); end if;
  -- peaceful regeneration (ServerPlayer.tickRegeneration, per player every 20 ticks of its own tick count): +1 health, +1 saturation (up to 20); every 10 ticks +1 food
  if diff = 0 and regen then
    update mc.player p set health = case when (p_cur - p.join_tick) % 20 = 0 and p.health < 20 then least(p.health + 1::real, 20::real) else p.health end,
                           saturation = case when (p_cur - p.join_tick) % 20 = 0 and p.saturation < 20 then p.saturation + 1::real else p.saturation end,
                           food = case when (p_cur - p.join_tick) % 10 = 0 and p.food < 20 then p.food + 1 else p.food end
     where p.conn_id is not null and (p_ids is null or p.entity_id = any (p_ids)) and not p.dead and p.join_tick is not null and ((p_cur - p.join_tick) % 10 = 0)
       and (((p_cur - p.join_tick) % 20 = 0 and (p.health < 20 or p.saturation < 20)) or p.food < 20);
  end if;
end $$;

------------------------------------------------------------------------------------------------ sync: set_health, set_experience
-- ServerPlayer.doTick: set_health when the health, the food level or "saturation is zero" differ from what the client was last told (a saturation change alone sends
-- nothing); set_experience when the total changed (every xp function sets sent_xp_total = -1 to force it).
create or replace function mc.survival_sync(p_cur bigint, p_ids int[] default null) returns void language plpgsql as $$
begin
  with u as (
    update mc.player p set sent_health = p.health, sent_food = p.food, sent_sat_zero = (p.saturation = 0)
     where p.conn_id is not null and (p_ids is null or p.entity_id = any (p_ids)) and (p.sent_health is distinct from p.health or p.sent_food is distinct from p.food or p.sent_sat_zero is distinct from (p.saturation = 0))
    returning p.conn_id, p.entity_id, p.health, p.food, p.saturation)
  insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_set_health(health, food, saturation) from u order by entity_id;
  with u as (
    update mc.player p set sent_xp_total = p.xp_total
     where p.conn_id is not null and (p_ids is null or p.entity_id = any (p_ids)) and p.sent_xp_total is distinct from p.xp_total
    returning p.conn_id, p.entity_id, p.xp_progress, p.xp_level, p.xp_total)
  insert into mc.play_out (conn_id, data) select conn_id, mc.pkt_set_experience(xp_progress, xp_level, xp_total) from u order by entity_id;
end $$;
