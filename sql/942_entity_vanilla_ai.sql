-- Vanilla-like mob behaviour for the entity simulation (docs/WHY-MOBS-COST.md section 10).  The rules, read from the 26.3 jar (javap -c -p) and checked against the real server
-- (tools/entity/vanilla_walkshare.py):
--
--   * goal selection runs every SECOND tick, (tickCount + entityId) % 2 == 0 (Mob.serverAiStep);
--   * RandomStrollGoal.canUse: random.nextInt(reducedTickDelay(120)) == 0, that is 1 in 60 per evaluation: a stroll starts after 2 * Geometric(1/60) ticks (mean 120) of standing;
--   * ... but only while noActionTime < 100; Mob.checkDespawn resets noActionTime to 0 only when the nearest player is closer than 32 blocks (MobCategory.CREATURE no-despawn
--     distance), so a cow farther than 32 blocks from every player never starts a stroll (measured: 0 % walking at 40-130 blocks, 28 % within 24);
--   * entities are ticked only inside the simulation distance of a player (ServerLevel.tick: DistanceManager.inEntityTickingRange): a mob farther away does nothing at all;
--   * the stroll target is a random block within +-10 horizontally (LandRandomPos.getPos(mob, 10, 7): random.nextInt(21) - 10 on both axes), reached by A* pathfinding at the
--     mob's movement speed; the walk takes (path length) / speed ticks.
--
-- What dbcraft does with them (and where it deliberately differs):
--   * the wait is drawn in closed form from a hash of (id, tick): decision tick = first evaluation tick + 2 * (G - 1), G ~ Geometric(1/60); a stand segment of a lane lasts until then;
--   * at that tick the mob DECIDES: a player (not a spectator) within 32 blocks of it -> a stroll to a random block within +-10: straight line, velocity = displacement / duration,
--     duration = octile path length / the type's stroll speed (a stand-in for A*: no obstacles); no player within 32 blocks but one within 2 chunks -> draw the next wait; NO player within
--     2 chunks (the 32-block circle fits into the 5x5 chunks around a player's chunk) -> DORMANT: the mob stands, its lane row says so (dormant = true, gend = 2^62) and NOTHING is
--     simulated for it until a player comes within 2 chunks (mc.entity_viewers_refresh wakes it: it draws a wait from that tick, as vanilla's noActionTime reset does).  Dormant mobs
--     cost no events and no scans: this is also vanilla's "entities beyond the simulation distance cost nothing" (2 chunks < any simulation distance >= 2);
--   * the 100-tick grace of noActionTime (a stroll can still start up to 5 seconds after the last player was near) and the freezing of a stroll that is in progress when the last player
--     leaves the simulation distance are NOT modelled: the stroll ends first, then the mob goes dormant;
--   * the old behaviour (60 % of the goals walks of 20-79 ticks, 40 % stands of 40-139, wherever the mob is) stays reachable: SET dbcraft.entity_ai = 'wander' (the default is 'vanilla').
-- Everything here is a pure function of (id, tick, position, players), so lazy replays and tick-by-tick runs agree (tests/sql/942).

alter table mc.entity_type_param add column if not exists stroll_speed float8;       -- mobs: blocks per tick while strolling (vanilla's cow: 1.76 blocks per second at the 75th-99th percentile of the moving seconds, tools/entity/walkshare_stats.py: 0.088); null: walk_speed
update mc.entity_type_param set stroll_speed = 0.088 where type = 'minecraft:cow' and stroll_speed is null;

create or replace function mc.entity_ai_vanilla() returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('dbcraft.entity_ai', true), ''), 'vanilla') <> 'wander'
$$;

-- the tick of the next decision after standing (or arriving) at tick p_tick - 1: the first evaluation tick after p_tick, plus 2 * (G - 1) with G ~ Geometric(1/60)
create or replace function mc.entity_stroll_wait(p_id int, p_tick bigint, p_born bigint) returns bigint language sql immutable parallel safe as $$
  select tf.t + 2 * (greatest(1, ceil(ln(1.0 - h.u) / ln(59.0 / 60)))::bigint - 1)
    from (select (abs(hashtextextended(p_id::text || ':w:' || p_tick::text, 3)) % 1000000007) / 1000000007.0 as u) h,
         lateral (select p_tick + 1 + ((((p_born - p_id - (p_tick + 1)) % 2) + 2) % 2) as t) tf
$$;

-- the goal drawn at tick p_tick for a mob that stood (p_prev_walk false: a DECISION) or arrived (true: draw the next wait); position and chunk cell of the mob, p_near = chunk radius of the dormancy test
create or replace function mc.entity_goal_v(p_id int, p_tick bigint, p_yaw real, p_speed float8, p_born bigint, p_prev_walk boolean, p_x float8, p_y float8, p_z float8, p_cx int, p_cz int, p_near int)
returns table (gx float8, gz float8, dur bigint, yaw real, dormant boolean) language sql stable as $$
  select case when d.stroll then d.dx / d.dur else 0 end, case when d.stroll then d.dz / d.dur else 0 end,
         case when d.stroll then d.dur when d.dorm then 1000000 else w.t - p_tick end,
         case when d.stroll then degrees(atan2(-d.dx, d.dz))::real else p_yaw end, d.dorm
    from (select mc.entity_stroll_wait(p_id, p_tick, p_born) as t) w
    cross join lateral (select abs(hashtextextended(p_id::text || ':g:' || p_tick::text, 5)) as hv) h
    cross join lateral (select not p_prev_walk and p_tick - p_born > 1 as decide,
                               (h.hv % 21) - 10 as ox, ((h.hv / 21) % 21) - 10 as oz) a
    cross join lateral (select a.decide and exists (select 1 from mc.entity_viewer_cell v join mc.player pl on pl.conn_id = v.conn_id
                                                      where abs(v.cx - p_cx) <= p_near and abs(v.cz - p_cz) <= p_near and pl.gamemode <> 3
                                                        and (pl.x - p_x) ^ 2 + (pl.y - p_y) ^ 2 + (pl.z - p_z) ^ 2 < 1024) as inside,
                               a.decide and not exists (select 1 from mc.entity_viewer_cell v where abs(v.cx - p_cx) <= p_near and abs(v.cz - p_cz) <= p_near) as dorm) b
    cross join lateral (select floor(p_x) + a.ox + 0.5 - p_x as dx, floor(p_z) + a.oz + 0.5 - p_z as dz) t
    cross join lateral (select b.inside and (t.dx ^ 2 + t.dz ^ 2) >= 1.0 as stroll,
                               greatest(2, ceil(((greatest(abs(t.dx), abs(t.dz)) - least(abs(t.dx), abs(t.dz))) + 1.4142135623731 * least(abs(t.dx), abs(t.dz))) / p_speed))::bigint as dur,
                               t.dx, t.dz, b.dorm) d
$$;

-- the chunk radius of the dormancy test and of the wake-up: a 32-block circle around a player fits into the 5x5 chunks around the player's chunk; never more than the simulation distance
create or replace function mc.entity_dormant_radius() returns int language sql stable as $$
  select least(2, greatest(0, coalesce(mc.prop_int('simulation-distance'), 2)))
$$;
