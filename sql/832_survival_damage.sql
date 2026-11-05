-- Survival core, part 3: damage, death, experience.  Every function takes SETS (arrays of entity ids) and does the work in a fixed number of statements.
--
-- mc.hurt(entity ids, amounts, damage type, tick)  =  ServerPlayer.hurtServer / Player.hurtServer / LivingEntity.hurtServer / Player.actuallyHurt:
--   * a game mode with the invulnerable ability (creative, spectator) takes nothing, unless the type is in the tag bypasses_invulnerability (void, /kill)
--   * a game rule can switch a type off (fall_damage); a dead player takes nothing
--   * damage scaled by difficulty only for types whose `scaling` says so (explosions: always; mob damage: needs a living non-player attacker, not modelled)
--   * damage cooldown: for 10 ticks after a full hit only the part above the last hit counts and no event is sent (LivingEntity.damageCooldownTime > 10)
--   * armor, enchantments, effects, absorption, shields are NOT modelled (no armor values in the data this server has)
--   * the type's exhaustion is added (not for invulnerable game modes: causeFoodExhaustion returns), health drops, the combat window is updated
--   * a full hit tells the player and everyone who sees them (damage_event); health at 0 or below kills (mc.survival_die)
-- The health the client sees follows in mc.survival_sync (set_health from the owner's tick, set_entity_data one tick later for damage from the entity tick, in the same
-- tick for damage that came with the player's own packets: the order of vanilla's tracker pass and entity tick).

create or replace function mc.send_players_and_viewers(p_eids int[], p_data bytea[], p_self boolean default true) returns void language sql as $$
  insert into mc.play_out (conn_id, data)
  select r.conn, string_agg(r.d, '\x'::bytea order by r.ord)
    from (select p.conn_id as conn, t.d, t.ord from unnest(p_eids, p_data) with ordinality t(eid, d, ord) join mc.player p on p.entity_id = t.eid where p_self and p.conn_id is not null
          union all
          select v.viewer_conn, t.d, t.ord from unnest(p_eids, p_data) with ordinality t(eid, d, ord) join mc.visible v on v.target_eid = t.eid) r
   group by r.conn order by r.conn $$;

create or replace function mc.survival_die(p_eids int[], p_cur bigint) returns void language plpgsql as $$
declare show_msg boolean := mc.rule_bool('show_death_messages', true); keep boolean := mc.rule_bool('keep_inventory', false);
        can_drop boolean := mc.entity_mode() = 'inline';
begin
  if cardinality(p_eids) = 0 then return; end if;
  -- the message (CombatTracker.getDeathMessage) and the death location
  if to_regclass('pg_temp._dying') is null then create temp table _dying (eid int primary key, conn int, uuid uuid, name text, gm int, x float8, y float8, z float8, msg bytea) on commit delete rows; end if;
  delete from _dying;
  insert into _dying
  select p.entity_id, p.conn_id, p.uuid, p.name, p.gamemode, p.x, p.y, p.z, proto.nbt_root(mc.death_message(p.uuid, p.name, p.cb_type, p.cb_fall))
    from mc.player p where p.entity_id = any (p_eids) and p.conn_id is not null;
  update mc.player p set dead = true, death_tick = p_cur, death_x = floor(d.x), death_y = floor(d.y), death_z = floor(d.z), use_slot = null, use_until = null, sprinting = false, health = 0
    from _dying d where p.entity_id = d.eid;
  -- to the player: the death screen, then the message to everyone (system chat), then the death event to the player and the viewers.  A rule can silence the message.
  insert into mc.play_out (conn_id, data)
  select d.conn, mc.pkt_combat_kill(d.eid, case when show_msg then d.msg else mc.nbt_root_text('') end) from _dying d order by d.eid;
  if show_msg then
    insert into mc.play_out (conn_id, data)
    select o.conn_id, string_agg(mc.pkt_system_chat(d.msg), '\x'::bytea order by d.eid) from _dying d, mc.player o where o.conn_id is not null group by o.conn_id order by o.conn_id;
  end if;
  perform mc.send_players_and_viewers(array_agg(d.eid order by d.eid), array_agg(mc.pkt_entity_event(d.eid, 3) order by d.eid)) from _dying d;
  -- what they carried falls to the ground (Inventory.dropAll: one item entity per stack, thrown a little to a random side) unless keepInventory or a spectator; with the
  -- entity simulation off or on its own connection there is nobody to simulate or show the items: they are removed (docs/SURVIVAL.md)
  if not keep then
    if can_drop then
      perform mc.entity_spawn('minecraft:item', d.x, d.y + 1.32, d.z, -sin(a) * f, 0.2, cos(a) * f, p_cur, jsonb_build_object('item', s.item, 'count', s.count), 40)
        from _dying d join mc.inventory_slot s on s.player = d.uuid
        cross join lateral (select random() * 0.5 as f, random() * 2 * pi() as a) r
        where d.gm <> 3 order by d.eid, s.slot;
    end if;
    delete from mc.inventory_slot s using _dying d where s.player = d.uuid and d.gm <> 3;
    update mc.player p set inv_state = inv_state + 1 from _dying d where p.entity_id = d.eid and d.gm <> 3;
  end if;
end $$;

create or replace function mc.hurt(p_eids int[], p_amounts real[], p_type text, p_cur bigint) returns int language plpgsql as $$
declare dt mc.damage_type; bypass_inv boolean; bypass_cd boolean; blocked boolean; n int; diff int := mc.difficulty();
        full_eids int[]; dead_eids int[];
begin
  select * into dt from mc.damage_type where name = 'minecraft:' || p_type;
  if dt.id is null then raise exception 'unknown damage type %', p_type using errcode = '22023'; end if;
  bypass_inv := mc.damage_tag('bypasses_invulnerability', p_type); bypass_cd := mc.damage_tag('bypasses_cooldown', p_type);
  blocked := (mc.damage_tag('is_fall', p_type) and not mc.rule_bool('fall_damage', true))
          or (mc.damage_tag('is_drowning', p_type) and not mc.rule_bool('drowning_damage', true))
          or (mc.damage_tag('is_fire', p_type) and not mc.rule_bool('fire_damage', true))
          or (mc.damage_tag('is_freezing', p_type) and not mc.rule_bool('freeze_damage', true));
  if blocked then return 0; end if;
  with a as (
    select p.entity_id as eid, p.uuid, p.gamemode, p.health, p.exhaustion, p.last_hurt, p.hurt_tick, p.cb_tick, p.cb_fall, p.fall_distance,
           -- Player.hurtServer: difficulty scaling (float arithmetic as in the class: easy min(a/2+1, a), hard a*3/2, peaceful 0)
           case when dt.scaling = 'always' then case diff when 0 then 0::real when 1 then least(t.amt / 2::real + 1::real, t.amt) when 3 then t.amt * 3::real / 2::real else t.amt end else t.amt end as amt,
           (p.gamemode in (1, 3)) as invul
      from unnest(p_eids, p_amounts) as t(eid, amt) join mc.player p on p.entity_id = t.eid
     where p.conn_id is not null and not p.dead and p.health > 0 and (bypass_inv or p.gamemode not in (1, 3))),
  b as (
    select a.*, (not bypass_cd and a.hurt_tick is not null and p_cur - a.hurt_tick < 10) as cooling from a where a.amt > 0),
  c as (
    select b.*, case when b.cooling then b.amt - b.last_hurt else b.amt end as dmg from b where not b.cooling or b.amt > b.last_hurt),
  u as (
    update mc.player p set
        health = p.health - c.dmg,
        last_hurt = c.amt, hurt_tick = case when c.cooling then p.hurt_tick else p_cur end,
        exhaustion = case when c.invul then p.exhaustion else least(p.exhaustion + dt.exhaustion, 40::real) end,
        cb_fall = greatest(case when p.cb_tick is null or p_cur - p.cb_tick > 100 then 0 else p.cb_fall end, case when mc.damage_tag('is_fall', p_type) then p.fall_distance::real else 0 end),
        cb_tick = p_cur, cb_type = p_type
      from c where p.entity_id = c.eid
    returning p.entity_id as eid, p.health as nh, c.cooling as cooling)
  select count(*)::int, coalesce(array_agg(eid order by eid) filter (where not cooling), '{}'), coalesce(array_agg(eid order by eid) filter (where nh <= 0), '{}')
    into n, full_eids, dead_eids from u;
  if cardinality(full_eids) > 0 then
    perform mc.send_players_and_viewers(full_eids, array(select mc.pkt_damage_event(e, dt.id) from unnest(full_eids) e));
    perform mc.snd_hurt(full_eids, dead_eids, p_type);                          -- (sql/1030) the hurt or death sound for the others, right after the damage event (recorded)
  end if;
  perform mc.survival_die(dead_eids, p_cur);
  return n;
end $$;

-- one player by uuid (commands, tests): the amount is in half hearts like vanilla's
create or replace function mc.damage(p_uuid uuid, p_amount real, p_type text default 'generic') returns int language sql as $$
  select mc.hurt(array[entity_id], array[p_amount], p_type, (select game_time from mc.game_state)) from mc.player where uuid = p_uuid and entity_id is not null $$;

-- /kill: genericKill, 3.4028235E38 (Float.MAX_VALUE), bypasses invulnerability and the cooldown
create or replace function mc.kill_players(p_uuids uuid[]) returns int language sql as $$
  select coalesce(sum(mc.hurt(array[entity_id], array['3.4028235E38'::real], 'generic_kill', (select game_time from mc.game_state))), 0)::int
    from mc.player where uuid = any (p_uuids) and entity_id is not null $$;

------------------------------------------------------------------------------------------------ healing
-- LivingEntity.heal: no change for a dead player; the cap is the maximum health (20)
create or replace function mc.heal(p_uuid uuid, p_amount real) returns void language sql as $$
  update mc.player set health = least(health + p_amount, 20::real) where uuid = p_uuid and health > 0 and not dead $$;

------------------------------------------------------------------------------------------------ experience (Player.giveExperiencePoints & friends, float arithmetic as in the class)
create or replace function mc.xp_needed(p_level int) returns int language sql immutable parallel safe as $$
  select case when p_level >= 30 then 112 + (p_level - 30) * 9 when p_level >= 15 then 37 + (p_level - 15) * 5 else 7 + p_level * 2 end $$;

-- giveExperiencePoints(points): the score and the total grow, the progress bar moves, levels roll over in both directions
create or replace function mc.xp_give(p_uuid uuid, p_points int) returns void language plpgsql as $$
declare p mc.player; lvl int; prog real; tot int; need int; rest real;
begin
  if p_points = 0 then return; end if;
  select * into p from mc.player where uuid = p_uuid; if not found then return; end if;
  lvl := p.xp_level; prog := p.xp_progress + p_points::real / mc.xp_needed(lvl)::real;
  tot := greatest(0, least(p.xp_total::bigint + p_points, 2147483647))::int;
  while prog < 0 loop
    rest := prog * mc.xp_needed(lvl)::real;
    lvl := lvl - 1;
    if lvl < 0 then lvl := 0; prog := 0; tot := 0; else prog := 1::real + rest / mc.xp_needed(lvl)::real; end if;
    if lvl = 0 and prog < 0 then prog := 0; end if;
  end loop;
  while prog >= 1 loop
    prog := (prog - 1::real) * mc.xp_needed(lvl)::real; lvl := lvl + 1; prog := prog / mc.xp_needed(lvl)::real;
  end loop;
  update mc.player set xp_level = lvl, xp_progress = prog, xp_total = tot, xp_score = xp_score + p_points, sent_xp_total = -1 where uuid = p_uuid;
end $$;

-- giveExperienceLevels(n): the level moves, the total and progress are untouched unless the level would go below 0 (all three reset)
create or replace function mc.xp_give_levels(p_uuid uuid, p_levels int) returns void language sql as $$
  update mc.player set xp_level = greatest(0, xp_level + p_levels),
                       xp_progress = case when xp_level + p_levels < 0 then 0 else xp_progress end, xp_total = case when xp_level + p_levels < 0 then 0 else xp_total end,
                       sent_xp_total = -1
   where uuid = p_uuid and p_levels <> 0 $$;
-- setExperienceLevels(n) / setExperiencePoints(n): the same packets, no change to the total
create or replace function mc.xp_set_levels(p_uuid uuid, p_level int) returns void language sql as $$
  update mc.player set xp_level = p_level, sent_xp_total = -1 where uuid = p_uuid and xp_level <> p_level $$;
create or replace function mc.xp_set_points(p_uuid uuid, p_points int) returns void language sql as $$
  update mc.player set xp_progress = greatest(0, least(p_points::real / mc.xp_needed(xp_level)::real, (mc.xp_needed(xp_level) - 1)::real / mc.xp_needed(xp_level)::real)), sent_xp_total = -1
   where uuid = p_uuid $$;
