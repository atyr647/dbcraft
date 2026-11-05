-- Autonomous entity lanes (docs/PERF-MOBS2.md).  The lanes of sql/541 (dead reckoning for ONE goal, entity row rewritten at every goal, lane row rewritten at every tracker step) become
-- lanes that carry a mob through its whole life on flat ground:
--
--   * the lane row is the complete state of the mob (position anchor, velocity, goal, chunk, delta base): the wide mc.entity row is not read and not written while the lane lasts;
--   * a tracker step (every 3rd tick) writes NOTHING: the packet is a function of the lane row and the tick (the viewers' delta base after a step is the position one step earlier,
--     which the closed form gives; only the FIRST step of a segment reads the stored base);
--   * the next goal is drawn inside the lane (same hash, same distribution as mc.entity_ai_ids) and costs one narrow row update, not a flush + AI + lane-try of the wide row;
--   * the lane ends (the mob goes back to the exact sweep) at the chunk border, when the next goal's footprint is not on a uniform floor, on a block change nearby, or when the
--     tick sequence has a gap (mc.entity_auto_rebase).  mc.entity_auto_end brings the entity row up to date.
--   * LAZY LANES (docs/PERF-MOBS2.md part 2): a lane whose cell is farther than min(tracking range, view radius) + 1 chunks from every viewer cannot be seen and sends nothing.  It is not
--     simulated every tick: its segments are REPLAYED every 32nd tick (id % 32), each with the tick it expired at, which is exactly what a tick-by-tick run computes (the goal is a hash of
--     (id, tick), the walk a closed form).  Whoever is about to look first catches the lane up (mc.entity_auto_catchup: a viewer's new cells, a block or floor change, a gap in the ticks,
--     the end of a lane); a viewer who comes within reach turns the lanes around him eager again (mc.entity_viewers_refresh).  dbcraft.entity_lazy = 'off': everything is eager.
-- Mobs that chase (zombies: re-aim every 5 ticks) keep the lanes of sql/541 (auto = false).  dbcraft.entity_auto = 'off' routes everybody there.
--
-- Standing mobs are lanes too (velocity 0): no step at all except ONE packet in the first tick of the segment that delivers the final position of the walk before it (the
-- "last look" of the generic tracker for a mob that goes to sleep), then nothing.  Vanilla sends a zero move every 60 ticks even for a standing mob; so does not dbcraft (deliberate,
-- as for items: docs/ENTITY.md).

create unlogged table if not exists mc.entity_clock (id boolean primary key default true check (id), last_tick bigint) with (fillfactor = 50);
insert into mc.entity_clock (id, last_tick) values (true, null) on conflict do nothing;

alter table mc.entity_lane add column if not exists auto boolean not null default false;     -- autonomous lane (this file); false: the lanes of sql/541
alter table mc.entity_lane add column if not exists t0 bigint;                                -- the anchor tick: the position is x0 + gx * (t - t0)
alter table mc.entity_lane add column if not exists x0 float8;
alter table mc.entity_lane add column if not exists z0 float8;
alter table mc.entity_lane add column if not exists y float8;
alter table mc.entity_lane add column if not exists gx float8;                                -- velocity of the segment (blocks per tick); 0, 0 = standing
alter table mc.entity_lane add column if not exists gz float8;
alter table mc.entity_lane add column if not exists gend bigint;                              -- the tick the goal ends (the AI draws the next one); goal_until is the end of the SEGMENT (goal end or chunk border)
alter table mc.entity_lane add column if not exists yaw real;
alter table mc.entity_lane add column if not exists pitch real;
alter table mc.entity_lane add column if not exists cx int;
alter table mc.entity_lane add column if not exists cz int;
alter table mc.entity_lane add column if not exists trk smallint;                             -- tracking range (chunks) of the type
alter table mc.entity_lane add column if not exists born bigint;
alter table mc.entity_lane add column if not exists hw float8;                                  -- half width of the type (footprint of a walk)
alter table mc.entity_lane add column if not exists wsp float8;                                 -- walk speed of the type
alter table mc.entity_lane add column if not exists dim text;                                 -- dimension of the mob (floor summaries are per dimension)
alter table mc.entity_lane add column if not exists lazy boolean not null default false;     -- nobody can see the mob: replayed every 32nd tick instead of simulated every tick (mc.entity_watched)
alter table mc.entity_lane add column if not exists ucx int;                                    -- the cell whose 3x3 chunk neighbourhood was found uniform (uok) or not at the level of the lane's feet; null: unknown
alter table mc.entity_lane add column if not exists ucz int;
alter table mc.entity_lane add column if not exists uok boolean;
alter table mc.entity_lane add column if not exists dormant boolean not null default false;   -- vanilla-like AI (sql/942): standing, nobody within 2 chunks: no events until mc.entity_viewers_refresh wakes it (gend = 2^62)
alter table mc.entity_lane add column if not exists phead bytea;                              -- move_entity_pos packet of this mob without the three deltas (everything that does not change between steps)


------------------------------------------------------------------------------------------------ the AI of sql/541 (mc.entity_ai_ids, wander part) as a function: same hash, same numbers
create or replace function mc.entity_goal(p_id int, p_tick bigint, p_yaw real, p_walk_speed float8, wp float8)
returns table (gx float8, gz float8, dur int, yaw real) language sql immutable parallel safe as $$
  select case when q.r1 < wp then -sin(radians(q.r2 * 360)) * q.speed else 0 end as gx, case when q.r1 < wp then cos(radians(q.r2 * 360)) * q.speed else 0 end as gz,
         case when q.r1 < wp then 20 + floor(q.r4 * 60)::int else 40 + floor(q.r4 * 100)::int end as dur,
         case when q.r1 < wp then (q.r2 * 360)::real else q.yaw end as yaw
    from (select p_yaw as yaw, p_walk_speed * (0.6 + 0.4 * h.r3) as speed, h.r1, h.r2, h.r4
            from (select abs(hashtextextended(p_id::text || ':' || p_tick::text, 0)) as hv) hh
            cross join lateral (select (hh.hv % 1000) / 1000.0 as r1, ((hh.hv / 1000) % 1000) / 1000.0 as r2, ((hh.hv / 1000000) % 1000) / 1000.0 as r3, ((hh.hv / 1000000000) % 1000) / 1000.0 as r4) h) q
$$;

------------------------------------------------------------------------------------------------ what the viewers hold
-- The delta base of an autonomous lane after every step with tick <= p_last has run (steps run at the ticks t > t0 with t = slot (mod every) while t < the segment end, standing
-- segments only once, at t0 + 1).  Walking: the position at the last step (every step moves at least 40 quantisation units, so every step sends); standing: the one step sends when its
-- delta is large enough (or on the forced 60-tick phase).  The yaw base becomes the lane's yaw as soon as one step ran and the angle byte differed.
create or replace function mc.entity_auto_base(t0 bigint, every int, slot int, x0 float8, z0 float8, y float8, gx float8, gz float8, yaw real, lend bigint, born bigint,
                                               sqx bigint, sqy bigint, sqz bigint, syaw real, last_tick bigint, p_last bigint)
returns table (bx bigint, "by" bigint, bz bigint, byaw real, blast bigint) language sql immutable parallel safe as $$
  select case when r.ran and a.walking then mc.quant(x0 + gx * (d.ls - t0)) when r.ran and f.pos_ch1 then mc.quant(x0) else sqx end,
         case when r.ran and (a.walking or f.pos_ch1) then mc.quant(y) else sqy end,
         case when r.ran and a.walking then mc.quant(z0 + gz * (d.ls - t0)) when r.ran and f.pos_ch1 then mc.quant(z0) else sqz end,
         case when r.ran and abs(mc.angle_byte(yaw) - mc.angle_byte(syaw)) >= 1 then yaw else syaw end,
         case when r.ran and (a.walking or f.pos_ch1) then d.ls else last_tick end
    from (select (gx <> 0 or gz <> 0) as walking) a,
         lateral (select least(p_last, lend - 1) as lim) b,
         lateral (select case when a.walking then t0 + 1 + ((((slot - (t0 + 1)) % every) + every) % every) else t0 + 1 end as t1) c,
         lateral (select case when a.walking then b.lim - ((((b.lim - slot) % every) + every) % every) else c.t1 end as ls) d,
         lateral (select d.ls >= c.t1 and c.t1 <= b.lim as ran) r,
         lateral (select (not a.walking) and ((mc.quant(x0) - sqx) ^ 2 + (mc.quant(y) - sqy) ^ 2 + (mc.quant(z0) - sqz) ^ 2 >= 128 or (c.t1 - born) % 60 = 0) as pos_ch1) f
$$;

-- is the whole footprint of a walk (cells x0..x1, z0..z1) floor with its highest solid cell at fy - 1?  (the test of mc.entity_lane_try, sql/541)
create or replace function mc.entity_floor_ok(p_dim text, p_fy int, x0 int, x1 int, z0 int, z1 int) returns boolean language sql stable as $$
  select (z1 >> 4) - (z0 >> 4) <= 2 and (x1 >> 4) - (x0 >> 4) <= 2
     and (not exists (select 1 from (values (0), (1), (2)) d(i) join (values (0), (1), (2)) d2(i) on (x0 >> 4) + d.i <= (x1 >> 4) and (z0 >> 4) + d2.i <= (z1 >> 4)      -- (only the chunks the walk touches are probed)
                       left join lateral (select f0.top_min, f0.top_max from mc.entity_floor f0
                                           where f0.dimension = p_dim and f0.cx = (x0 >> 4) + d.i and f0.cz = (z0 >> 4) + d2.i offset 0) f on true
                      where f.top_min is distinct from p_fy - 1 or f.top_max is distinct from p_fy - 1)
          or not exists (select 1 from generate_series(x0, x1) gx(x) cross join generate_series(z0, z1) gz(z)
                          left join lateral (select f1.tops[((gz.z & 15) * 16 + (gx.x & 15)) + 1] as top from mc.entity_floor f1
                                              where f1.dimension = p_dim and f1.cx = gx.x >> 4 and f1.cz = gz.z >> 4 offset 0) f on true
                         where f.top is distinct from (p_fy - 1)))
$$;

-- is the floor of all nine chunks around (and in) the cell uniform at the level fy - 1?  Then any walk that stays within those chunks is on floor, without a probe per segment
-- (a verdict kept in the lane row for the cell it is about the lane is in: ucx, ucz, uok; cleared when a section of a chunk around changes: mc.entity_auto_floor_change)
create or replace function mc.entity_floor3(p_dim text, p_fy int, p_cx int, p_cz int) returns boolean language sql stable as $$
  select not exists (select 1 from (values (-1), (0), (1)) d(i) cross join (values (-1), (0), (1)) d2(i)
                      left join lateral (select f0.top_min, f0.top_max from mc.entity_floor f0 where f0.dimension = p_dim and f0.cx = p_cx + d.i and f0.cz = p_cz + d2.i offset 0) f on true
                     where f.top_min is distinct from p_fy - 1 or f.top_max is distinct from p_fy - 1)
$$;

------------------------------------------------------------------------------------------------ ending lanes: the entity row gets the state after tick p_pos (position) with the delta base of the steps up to p_base
create or replace function mc.entity_auto_end(p_ids int[], p_pos bigint, p_base bigint) returns int language plpgsql volatile as $$
declare n int;
begin
    if p_ids is null or cardinality(p_ids) = 0 then return 0; end if;
    -- p_pos null: the state at the anchor of the lane row (the lane ended at the tick its segment did, mc.entity_auto_run); otherwise lanes that are behind (lazy ones) are replayed first
    if p_pos is not null then perform mc.entity_auto_catchup(p_pos, p_ids); end if;
    with u as (
        update mc.entity e set x = l.x0 + l.gx * greatest(coalesce(p_pos, l.t0) - l.t0, 0), z = l.z0 + l.gz * greatest(coalesce(p_pos, l.t0) - l.t0, 0), phys_tick = greatest(coalesce(p_pos, l.t0), l.t0), lane_until = 0,
               goal_until = l.gend, gx = l.gx, gz = l.gz, vx = l.gx, vz = l.gz, yaw = l.yaw,
               cx = floor((l.x0 + l.gx * greatest(coalesce(p_pos, l.t0) - l.t0, 0)) / 16)::int, cz = floor((l.z0 + l.gz * greatest(coalesce(p_pos, l.t0) - l.t0, 0)) / 16)::int,
               sent_qx = b.bx, sent_qy = b."by", sent_qz = b.bz, sent_yaw = b.byaw, last_sent_tick = b.blast
          from (select l0.* from mc.entity_lane l0 where l0.id = any(p_ids) and l0.auto) l
          cross join lateral mc.entity_auto_base(l.t0, l.every, l.slot, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.goal_until, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick, coalesce(p_base, l.t0)) b
         where e.id = l.id returning e.id)
    delete from mc.entity_lane d using u where d.id = u.id;
    get diagnostics n = row_count;
    return n;
end $$;

-- ticks are not consecutive any more (the entity connection jumped ahead, mc.entity_loop): the steps that did not run must not be assumed to have run.  Every autonomous lane is
-- re-anchored at tick p_anchor (the tick before the one that is about to run: positions are closed forms, the skipped ticks are walked) with the viewers' real delta base stored (the
-- steps up to p_prev, the last tick that did run): its next step is a "first step" again.
drop function if exists mc.entity_auto_rebase(bigint);
create or replace function mc.entity_auto_rebase(p_prev bigint, p_anchor bigint) returns int language plpgsql volatile as $$
declare n int; ids int[]; bx bigint[]; bby bigint[]; bz bigint[]; byaw real[]; bl bigint[];
begin
    -- lanes that are behind the anchor (their segment ended during the gap, or they are lazy): the viewers' real delta base is the one of the steps up to p_prev in the segment they were in;
    -- replay them to the anchor, then restore that base
    select array_agg(o.id), array_agg(b.bx), array_agg(b."by"), array_agg(b.bz), array_agg(b.byaw), array_agg(b.blast) into ids, bx, bby, bz, byaw, bl
      from mc.entity_lane o cross join lateral mc.entity_auto_base(o.t0, o.every, o.slot, o.x0, o.z0, o.y, o.gx, o.gz, o.yaw, o.goal_until, o.born, o.sqx, o.sqy, o.sqz, o.syaw, o.last_tick, p_prev) b
     where o.auto and o.goal_until <= p_anchor;
    if ids is not null then
        perform mc.entity_auto_catchup(p_anchor, ids);
        update mc.entity_lane l set sqx = u.bx, sqy = u.bby, sqz = u.bz, syaw = u.byaw, last_tick = u.bl
          from unnest(ids, bx, bby, bz, byaw, bl) u(id, bx, bby, bz, byaw, bl) where l.id = u.id;
    end if;
    update mc.entity_lane l set t0 = greatest(p_anchor, l.t0), x0 = l.x0 + l.gx * greatest(p_anchor - l.t0, 0), z0 = l.z0 + l.gz * greatest(p_anchor - l.t0, 0),
           sqx = b.bx, sqy = b."by", sqz = b.bz, syaw = b.byaw, last_tick = b.blast
      from (select l0.id, l0.t0, l0.every, l0.slot, l0.x0, l0.z0, l0.y, l0.gx, l0.gz, l0.yaw, l0.goal_until, l0.born, l0.sqx, l0.sqy, l0.sqz, l0.syaw, l0.last_tick from mc.entity_lane l0 where l0.auto) o
      cross join lateral mc.entity_auto_base(o.t0, o.every, o.slot, o.x0, o.z0, o.y, o.gx, o.gz, o.yaw, o.goal_until, o.born, o.sqx, o.sqy, o.sqz, o.syaw, o.last_tick, p_prev) b
     where l.id = o.id;
    get diagnostics n = row_count;
    return n;
end $$;

------------------------------------------------------------------------------------------------ chunk cells
-- Ticks after the anchor at which a walk at velocity g from position x (inside cell `cell`, 16 blocks wide) is FIRST outside the cell: exact for the closed form x + g * k that the
-- steps use (the division gives the candidate, the neighbours are checked with the same expression; 1000000 for g = 0).  A segment covers only ticks whose position is inside its cell.
create or replace function mc.entity_cell_exit(x float8, g float8, cell int) returns bigint language sql immutable parallel safe as $$
  select case when g > 0 then
                case when least(ceil((16.0 * (cell + 1) - x) / g), 1000000)::bigint > 1 and x + g * (least(ceil((16.0 * (cell + 1) - x) / g), 1000000)::bigint - 1) >= 16.0 * (cell + 1) then least(ceil((16.0 * (cell + 1) - x) / g), 1000000)::bigint - 1
                     when x + g * least(ceil((16.0 * (cell + 1) - x) / g), 1000000)::bigint >= 16.0 * (cell + 1) then least(ceil((16.0 * (cell + 1) - x) / g), 1000000)::bigint else least(ceil((16.0 * (cell + 1) - x) / g), 1000000)::bigint + 1 end
              when g < 0 then
                case when (least(floor((x - 16.0 * cell) / -g), 1000000)::bigint + 1) > 1 and x + g * ((least(floor((x - 16.0 * cell) / -g), 1000000)::bigint + 1) - 1) < 16.0 * cell then (least(floor((x - 16.0 * cell) / -g), 1000000)::bigint + 1) - 1
                     when x + g * (least(floor((x - 16.0 * cell) / -g), 1000000)::bigint + 1) < 16.0 * cell then (least(floor((x - 16.0 * cell) / -g), 1000000)::bigint + 1) else (least(floor((x - 16.0 * cell) / -g), 1000000)::bigint + 1) + 1 end
              else 1000000 end
$$;

-- Do the viewers of cell (cx, cz) within tracking range r see exactly the same viewers as those of cell (cx2, cz2)?  Then crossing from one to the other changes nothing for anybody
-- (no appearance, no removal), and a lane may cross the border without leaving the lane.
create or replace function mc.entity_view_same(p_cx int, p_cz int, p_cx2 int, p_cz2 int, r int) returns boolean language sql stable as $$
  select coalesce(array_agg(vv.conn_id order by vv.conn_id) filter (where vv.cx = p_cx and vv.cz = p_cz and greatest(abs(vc.cx - p_cx), abs(vc.cz - p_cz)) <= r), '{}')
       = coalesce(array_agg(vv.conn_id order by vv.conn_id) filter (where vv.cx = p_cx2 and vv.cz = p_cz2 and greatest(abs(vc.cx - p_cx2), abs(vc.cz - p_cz2)) <= r), '{}')
    from mc.entity_cell_viewer vv join mc.entity_viewer_cell vc on vc.conn_id = vv.conn_id
   where (vv.cx = p_cx and vv.cz = p_cz) or (vv.cx = p_cx2 and vv.cz = p_cz2)
$$;

------------------------------------------------------------------------------------------------ entering a lane
-- The mobs among p_ids that may start an autonomous lane now: standing on the ground at rest, y an integer (top of a full cube), announced and in the cell they were announced in,
-- and either standing (goal without velocity) or walking at a speed whose every step is sure to move far enough to be sent (>= 40 and < 30000 units per sampling interval) on a floor
-- that is uniform under the whole walk.  Same footprint rules as mc.entity_lane_cand (sql/541); the segment ends when the position is first outside the cell (mc.entity_cell_exit).
create or replace function mc.entity_auto_cand(p_tick bigint, p_ids int[])
returns table (id int, dimension text, fy int, lend bigint, cx0 int, cx1 int, cz0 int, cz1 int, x0 int, x1 int, z0 int, z1 int, walking boolean) language sql stable as $$
  select c.id, c.dimension, c.fy, c.lend, c.x0 >> 4, c.x1 >> 4, c.z0 >> 4, c.z1 >> 4, c.x0, c.x1, c.z0, c.z1, c.walking
    from (select q.id, q.dimension, q.fy, q.lend, q.walking,
                 floor(least(q.x, q.x + q.gx * (q.lend - q.phys_tick)) - q.hw - 1e-6)::int as x0, floor(greatest(q.x, q.x + q.gx * (q.lend - q.phys_tick)) + q.hw + 1e-6)::int as x1,
                 floor(least(q.z, q.z + q.gz * (q.lend - q.phys_tick)) - q.hw - 1e-6)::int as z0, floor(greatest(q.z, q.z + q.gz * (q.lend - q.phys_tick)) + q.hw + 1e-6)::int as z1
            from (select e.id, e.dimension, floor(e.y)::int as fy, e.x, e.z, e.gx, e.gz, e.phys_tick, p.width / 2 as hw, (e.gx <> 0 or e.gz <> 0) as walking,
                         least(e.goal_until, e.phys_tick + least(mc.entity_cell_exit(e.x, e.gx, e.cx), mc.entity_cell_exit(e.z, e.gz, e.cz))) as lend
                    from (select distinct i from unnest(p_ids) i) u(id)
                    cross join lateral (select e0.* from mc.entity e0 where e0.id = u.id offset 0) e         -- offset 0: one primary-key probe per id
                    join mc.entity_type_param p on p.type = e.type
                   where p.kind = 'mob' and not p.can_chase and e.on_ground and not e.deep_sleep and e.lane_until = 0 and e.vy = 0 and e.y = floor(e.y) and e.goal_until > 0
                     and e.last_sent_tick > 0 and e.sent_cx = e.cx and e.sent_cz = e.cz and e.pitch = e.sent_pitch and e.cx = floor(e.x / 16)::int and e.cz = floor(e.z / 16)::int
                     and (((e.gx = 0 and e.gz = 0) or (sqrt(e.gx * e.gx + e.gz * e.gz) * p.update_interval * 4096 between 40 and 30000))
                          and abs(e.gx) * p.update_interval * 4096 < 30000 and abs(e.gz) * p.update_interval * 4096 < 30000)) q
           where q.lend > p_tick + 1) c
$$;

create or replace function mc.entity_auto_try(p_tick bigint, p_ids int[]) returns int language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off set plan_cache_mode = force_generic_plan as $$
declare n int := 0; ids int[]; lends bigint[];
begin
    if p_ids is null or cardinality(p_ids) = 0 or not mc.entity_lanes_enabled() or not mc.entity_auto_enabled() then return 0; end if;
    perform mc.entity_floor_build(m.dimension, m.cx, m.cz)
       from (select distinct c.dimension, c.cx0 + d.i as cx, c.cz0 + d2.i as cz
               from mc.entity_auto_cand(p_tick, p_ids) c, (values (0), (1), (2)) d(i), (values (0), (1), (2)) d2(i)
              where c.walking and c.cx1 - c.cx0 <= 2 and c.cz1 - c.cz0 <= 2 and c.cx0 + d.i <= c.cx1 and c.cz0 + d2.i <= c.cz1
                and not exists (select 1 from mc.entity_floor f where f.dimension = c.dimension and f.cx = c.cx0 + d.i and f.cz = c.cz0 + d2.i and f.tops is not null)
              order by 1, 2, 3 limit 8) m;       -- at most 8 floor builds (about 1.7 ms each) per call: the others wait a tick
    select array_agg(c.id), array_agg(c.lend) into ids, lends from mc.entity_auto_cand(p_tick, p_ids) c where not c.walking or mc.entity_floor_ok(c.dimension, c.fy, c.x0, c.x1, c.z0, c.z1);
    if ids is null then return 0; end if;
    with ent as materialized (
        select e.id, e.dimension, e.x, e.y, e.z, e.gx, e.gz, e.yaw, e.pitch, e.phys_tick, e.goal_until, e.cx, e.cz, e.born_tick, e.sent_qx, e.sent_qy, e.sent_qz, e.sent_yaw, e.last_sent_tick,
               p.update_interval as every, ((e.born_tick % p.update_interval) + p.update_interval)::int % p.update_interval as slot, p.tracking_chunks as trk, p.width / 2 as hw, case when mc.entity_ai_vanilla() then coalesce(p.stroll_speed, p.walk_speed) else p.walk_speed end as wsp,
               u.lend
          from unnest(ids, lends) u(id, lend) cross join lateral (select e0.* from mc.entity e0 where e0.id = u.id offset 0) e join mc.entity_type_param p on p.type = e.type
    ), ins as (
        insert into mc.entity_lane (id, goal_until, every, slot, chase, sqx, sqy, sqz, syaw, last_tick, auto, t0, x0, z0, y, gx, gz, gend, yaw, pitch, cx, cz, trk, born, hw, wsp, dim, phead, lazy, dormant)
        select ent.id, ent.lend, ent.every, ent.slot, false, ent.sent_qx, ent.sent_qy, ent.sent_qz, ent.sent_yaw, ent.last_sent_tick, true, ent.phys_tick, ent.x, ent.z, ent.y, ent.gx, ent.gz,
               ent.goal_until, ent.yaw, ent.pitch, ent.cx, ent.cz, ent.trk, ent.born_tick, ent.hw, ent.wsp, ent.dimension,
               (select substring(h from 1 for octet_length(h) - 6) from (select mc.epkt_mob_move(ent.id, 0, 0, 0, ent.every, true, false, 0::real, 0::real) as h) hh),
               not mc.entity_watched(ent.cx, ent.cz, ent.trk) or ent.goal_until = 4611686018427387904, ent.goal_until = 4611686018427387904
          from ent
        on conflict (id) do update set goal_until = excluded.goal_until, every = excluded.every, slot = excluded.slot, chase = false, sqx = excluded.sqx, sqy = excluded.sqy, sqz = excluded.sqz,
               syaw = excluded.syaw, last_tick = excluded.last_tick, auto = true, t0 = excluded.t0, x0 = excluded.x0, z0 = excluded.z0, y = excluded.y, gx = excluded.gx, gz = excluded.gz,
               gend = excluded.gend, yaw = excluded.yaw, pitch = excluded.pitch, cx = excluded.cx, cz = excluded.cz, trk = excluded.trk, born = excluded.born, hw = excluded.hw, wsp = excluded.wsp, dim = excluded.dim,
               phead = excluded.phead, lazy = excluded.lazy, dormant = excluded.dormant
        returning id
    )
    -- the entity row stays as it is (its state is the anchor of the lane); it is marked as in a lane for good and out of the goal scan of the AI
    update mc.entity e set lane_until = 9223372036854775807, goal_until = 9223372036854775807, vx = e.gx, vz = e.gz, vy = 0 from ins where e.id = ins.id;
    get diagnostics n = row_count;
    return n;
end $$;

------------------------------------------------------------------------------------------------ fan-out of the per-cell blobs
-- Every viewer of a cell gets the blob of the cell once (tracking range at least the view distance: every viewer of the cell is in range by construction, no second probe).  Own function
-- because of its settings: the interest relation is tiny with a few viewers (the planner then scans it per blob: 40 us each, 4 ms for 100 blobs) and huge in a crowd (a scan is a disaster),
-- so every access is a primary-key probe.
create or replace function mc.entity_fan_cells(p_cx int[], p_cz int[], p_trk int[], p_blob bytea[]) returns int language plpgsql volatile
set enable_seqscan = off set enable_hashjoin = off set enable_mergejoin = off as $$
declare vr int := mc.prop_int('view-distance'); n int;
begin
    insert into mc.play_out (conn_id, data)
    select q.conn_id, string_agg(q.blob, '\x'::bytea)
      from (select v2.conn_id, cb.blob
              from unnest(p_cx, p_cz, p_trk, p_blob) cb(cx, cz, trk, blob) cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = cb.cx and vv.cz = cb.cz offset 0) v2
             where cb.trk >= vr
            union all
            select v2.conn_id, cb.blob
              from unnest(p_cx, p_cz, p_trk, p_blob) cb(cx, cz, trk, blob) cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = cb.cx and vv.cz = cb.cz offset 0) v2
              join mc.entity_viewer_cell vc on vc.conn_id = v2.conn_id and greatest(abs(vc.cx - cb.cx), abs(vc.cz - cb.cz)) <= cb.trk
             where cb.trk < vr) q
     group by q.conn_id order by q.conn_id;
    get diagnostics n = row_count;
    return n;
end $$;

------------------------------------------------------------------------------------------------ lazy lanes: nobody watches, nothing is simulated every tick
-- A lane whose cell is farther than min(tracking range, view radius) + 1 chunks from every viewer is LAZY: nobody can see its mob (and, as the viewers move one cell at a time, nobody can
-- get close to it without a refresh that wakes it: mc.entity_viewers_refresh).  Its whole future is a pure function of the lane row (the goal is a hash of (id, tick), the walk a closed form),
-- so it is not simulated tick by tick: it is REPLAYED every 32nd tick (its slot: id % 32), each expired segment with the tick it expired at (the same computation a tick-by-tick run makes at
-- that tick, to the last bit: tests/sql/940 L), and it sends no packets.  Whoever is about to look at a lane (a viewer's new cells, a block change, the end of a lane, a gap in the ticks)
-- catches it up first: mc.entity_auto_catchup.
create or replace function mc.entity_watched(p_cx int, p_cz int, p_trk int) returns boolean language sql stable as $$
  select coalesce(current_setting('dbcraft.entity_lazy', true), 'on') = 'off'
         or exists (select 1 from mc.entity_viewer_cell v where greatest(abs(v.cx - p_cx), abs(v.cz - p_cz)) <= least(p_trk, v.r) + 1)
$$;

------------------------------------------------------------------------------------------------ one tick of all autonomous lanes (ONE statement; lazy lanes only in their slot)
-- For the lanes whose segment ended (the eager ones: now; the lazy ones: when their slot comes, replaying every segment that expired) and the lanes whose tracker step is due (eager ones):
--   * segment over:   the goal is drawn if it is over (mc.entity_goal, the hash of mc.entity_ai_ids), else kept.  The lane goes on in a NEW SEGMENT (one row update: anchor moved to the
--                     end of tick tt - 1, tt = the tick the segment ended at; the viewers' base stored; the cell of the position at tt) if the next walk's footprint is on a uniform floor and,
--                     when the cell changes, the viewers of the two cells are the same (a border crossing nobody notices; the entity row gets the new cell if somebody may look).  Otherwise the lane
--                     ENDS: the entity row gets the state after tick tt - 1 and the goal (the new one if it was drawn: the AI of that tick is done), and the exact sweep simulates the mob from now on.
--   * step due:       the packet from the lane row alone: head || dx || 0 || dz.  The first step of a segment reads the stored base; a first step that cannot be expressed this way
--                     (position sync tick, delta over a short, a walk whose first step does not move) ends the lane and is returned for the generic tracker.
-- p_ids null: the work of tick p_tick (with p_steps: the steps);  p_ids given: bring exactly these lanes to the state after tick p_tick (no steps).  more: lanes still behind after this pass.
create or replace function mc.entity_auto_run(p_tick bigint, p_steps boolean, p_ids int[], out bad int[], out more int) returns record language plpgsql volatile
-- (one generic plan per session: the statement takes 13 ms to plan, and the custom plans PostgreSQL keeps choosing for it, because they look cheaper than the generic one, were the biggest cost of a tick)
set enable_hashjoin = off set enable_mergejoin = off set plan_cache_mode = force_generic_plan as $$
declare wp float8 := coalesce(nullif(current_setting('dbcraft.entity_walk_prob', true), '')::float8, 0.6);
        ex int[]; cr int[]; nmain int; bcx int[]; bcz int[]; btrk int[]; bblob bytea[];
        lz_off boolean := coalesce(current_setting('dbcraft.entity_lazy', true), 'on') = 'off'; vm boolean := mc.entity_ai_vanilla(); nr int := mc.entity_dormant_radius(); hv boolean; bx0 int; bx1 int; bz0 int; bz1 int; e_due boolean := true; e_step boolean := true; l_due boolean := true;
begin
    more := 0;
    -- the cells some viewer sees (a box around all of them: a superset); a lane outside it sends nothing, whatever its kind of lane
    select count(*) > 0, min(v.cx - v.r), max(v.cx + v.r), min(v.cz - v.r), max(v.cz + v.r) into hv, bx0, bx1, bz0, bz1 from mc.entity_viewer_cell v;
    -- what there is to do, from ONE pass over the eager lanes and one probe of the lazy slot (each statement below costs 0.7 ms of set-up even with nothing to do)
    if p_ids is null then
        select coalesce(bool_or(l.goal_until <= p_tick), false), coalesce(bool_or(l.cx between bx0 and bx1 and l.cz between bz0 and bz1), false) into e_due, e_step      -- (a lane that is due now steps in its new segment)
          from mc.entity_lane l where l.auto and not l.lazy;
        select exists (select 1 from mc.entity_lane l where l.auto and l.lazy and not l.dormant and l.id % 32 = (p_tick % 32)::int and l.goal_until <= p_tick) into l_due;
    end if;
    if p_ids is null and not e_due and not l_due then
        ex := null;
    else
    with s as materialized (
        select l.*, l.goal_until as tt from mc.entity_lane l where p_ids is null and l.auto and not l.lazy and l.goal_until <= p_tick
        union all
        select l.*, l.goal_until as tt from mc.entity_lane l where p_ids is null and l.auto and l.lazy and not l.dormant and l.id % 32 = (p_tick % 32)::int and l.goal_until <= p_tick
        union all
        select l.*, l.goal_until as tt from mc.entity_lane l where p_ids is not null and l.auto and l.id = any(p_ids) and l.goal_until <= p_tick
    ), g as materialized (
        -- the segment is over: the goal (new if it ran out) and the state at the end of tick tt - 1 (anchor of the next segment, delta base of the viewers)
        select s.id, s.tt, s.every, s.slot, s.y, s.pitch, s.cx as ocx, s.cz as ocz, s.lazy as olazy, s.trk, s.born, s.hw, s.wsp, s.dim, s.phead, s.ucx, s.ucz, s.uok,
               case when s.gend <= s.tt then coalesce(nv.gx, ng.gx) else s.gx end as ngx, case when s.gend <= s.tt then coalesce(nv.gz, ng.gz) else s.gz end as ngz,
               case when s.gend <= s.tt then (case when nv.dormant then 4611686018427387904 else s.tt + coalesce(nv.dur, ng.dur::bigint) end) else s.gend end as ngend,
               case when s.gend <= s.tt then coalesce(nv.yaw, ng.yaw) else s.yaw end as nyaw, coalesce(nv.dormant, false) as ndorm,
               s.x0 + s.gx * greatest(s.tt - 1 - s.t0, 0) as ax, s.z0 + s.gz * greatest(s.tt - 1 - s.t0, 0) as az,
               b.bx, b."by", b.bz, b.byaw, b.blast
          from s
          left join lateral (select * from mc.entity_goal(s.id, s.tt, s.yaw, s.wsp, wp) where s.gend <= s.tt and not vm) ng on true
          left join lateral (select * from mc.entity_goal_v(s.id, s.tt, s.yaw, s.wsp, s.born, (s.gx <> 0 or s.gz <> 0), s.x0 + s.gx * greatest(s.tt - 1 - s.t0, 0), s.y, s.z0 + s.gz * greatest(s.tt - 1 - s.t0, 0), s.cx, s.cz, nr)
                              where s.gend <= s.tt and vm) nv on true
          cross join lateral mc.entity_auto_base(s.t0, s.every, s.slot, s.x0, s.z0, s.y, s.gx, s.gz, s.yaw, s.goal_until, s.born, s.sqx, s.sqy, s.sqz, s.syaw, s.last_tick, s.tt - 1) b
    ), w as materialized (
        -- the cell of the position at tick tt, whether somebody may look at it, and whether the floor around it is uniform (a verdict kept for the cell)
        select q.*, case when lz_off then true when not hv or (q.olazy and q.ncx = q.ocx and q.ncz = q.ocz) then false else mc.entity_watched(q.ncx, q.ncz, q.trk) end as wat,      -- (a lazy lane that stays in its cell stays unwatched)
               case when q.ngx = 0 and q.ngz = 0 then null when q.ucx = q.ncx and q.ucz = q.ncz then q.uok else mc.entity_floor3(q.dim, floor(q.y)::int, q.ncx, q.ncz) end as uo
          from (select g.*, floor((g.ax + g.ngx) / 16)::int as ncx, floor((g.az + g.ngz) / 16)::int as ncz from g) q
    ), w2 as materialized (
        -- the end of the next segment (goal end or first tick outside that cell) and the cells the walk touches
        select w.*, q2.nlend,
               floor(least(w.ax, w.ax + w.ngx * (q2.nlend - (w.tt - 1))) - w.hw - 1e-6)::int as fx0, floor(greatest(w.ax, w.ax + w.ngx * (q2.nlend - (w.tt - 1))) + w.hw + 1e-6)::int as fx1,
               floor(least(w.az, w.az + w.ngz * (q2.nlend - (w.tt - 1))) - w.hw - 1e-6)::int as fz0, floor(greatest(w.az, w.az + w.ngz * (q2.nlend - (w.tt - 1))) + w.hw + 1e-6)::int as fz1
          from w cross join lateral (select least(w.ngend, (w.tt - 1) + least(mc.entity_cell_exit(w.ax, w.ngx, w.ncx), mc.entity_cell_exit(w.az, w.ngz, w.ncz))) as nlend) q2
    ), v as materialized (
        select w2.*, (w2.ncx <> w2.ocx or w2.ncz <> w2.ocz) as crossing,
               w2.nlend > w2.tt and (
                   (w2.ngx = 0 and w2.ngz = 0)
                   or (sqrt(w2.ngx * w2.ngx + w2.ngz * w2.ngz) * w2.every * 4096 between 40 and 30000 and abs(w2.ngx) * w2.every * 4096 < 30000 and abs(w2.ngz) * w2.every * 4096 < 30000
                       and ((w2.uo and (w2.fx0 >> 4) >= w2.ncx - 1 and (w2.fx1 >> 4) <= w2.ncx + 1 and (w2.fz0 >> 4) >= w2.ncz - 1 and (w2.fz1 >> 4) <= w2.ncz + 1)
                            or mc.entity_floor_ok(w2.dim, floor(w2.y)::int, w2.fx0, w2.fx1, w2.fz0, w2.fz1))))
               -- a border crossing keeps the lane when the viewers of the two cells are the same; between two cells nobody watches that is so by construction
               and ((w2.ncx = w2.ocx and w2.ncz = w2.ocz) or (w2.olazy and not w2.wat) or mc.entity_view_same(w2.ocx, w2.ocz, w2.ncx, w2.ncz, w2.trk)) as ok
          from w2
    ), upd as (
        -- every lane whose segment ended gets its anchor and goal moved (a lane that must end carries the new goal into its entity row)
        update mc.entity_lane l set goal_until = case when v.ok then v.nlend else v.tt end, t0 = v.tt - 1, x0 = v.ax, z0 = v.az, gx = v.ngx, gz = v.ngz, gend = v.ngend, yaw = v.nyaw,
               sqx = v.bx, sqy = v."by", sqz = v.bz, syaw = v.byaw, last_tick = v.blast, cx = case when v.ok then v.ncx else l.cx end, cz = case when v.ok then v.ncz else l.cz end,
               lazy = case when v.ok then (not v.wat) or v.ndorm else l.lazy end, dormant = case when v.ok then v.ndorm else l.dormant end,
               ucx = case when v.uo is not null then v.ncx else l.ucx end, ucz = case when v.uo is not null then v.ncz else l.ucz end, uok = coalesce(v.uo, l.uok)
          from v where l.id = v.id returning l.id
    )
    -- the segments that ended: the lanes that cannot go on (their entity rows get the state at the end of the segment), and how many are still behind
    select (select array_agg(v.id) from v where not v.ok), (select count(*)::int from v where v.ok and v.nlend <= p_tick),
           (select array_agg(v.id) from v where v.ok and v.crossing and (v.wat or not v.olazy)) into ex, more, cr;
    -- the mobs that crossed a border without anybody noticing: their entity row carries the cell (viewers refresh, despawn and the generic tracker read it).  A lazy lane that stays lazy leaves
    -- the entity row alone (mc.entity_auto_catchup copies the cell when somebody is about to look).  A separate statement: opening the indexes of the wide entity table costs more than the rest.
    if cr is not null then
        update mc.entity e set cx = l.cx, cz = l.cz, sent_cx = l.cx, sent_cz = l.cz from mc.entity_lane l where l.id = e.id and e.id = any(cr);
    end if;
    perform mc.entity_auto_end(ex, null, null);                          -- the lane ended at the tick its segment did: its row carries that state (and the goal that was drawn, or kept)
    end if;
    if p_steps and hv and e_step then
        -- the steps of the eager lanes (a lane that started a segment in this very tick is read from the table again: the first step of a segment reads the stored base)
        with cand as (
            select l.id, l.cx, l.cz, l.trk, l.every, l.t0, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.pitch, l.phead, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick
              from mc.entity_lane l
             where l.auto and not l.lazy and l.goal_until > p_tick and case when l.gx <> 0 or l.gz <> 0 then l.slot = (p_tick % l.every)::int else p_tick = l.t0 + 1 end
               and l.cx between bx0 and bx1 and l.cz between bz0 and bz1      -- (eager lanes in the margin around the viewers' cells: nobody to send to)
        ), main as materialized (
        select c.id, c.cx, c.cz, c.trk, k.bad,
               case when k.bad then null
                    when not f.first_ and k.sync then mc.epkt_sync(c.id, n.nx, c.y, n.nz, c.gx, 0::float8, c.gz, c.yaw, c.pitch, true)
                    when not f.first_ then c.phead || int4send(d.dx::int4 << 16) || int2send(d.dz::int2)
                    when k.pos_ch then mc.epkt_mob_move(c.id, d.dx::int, d.dy::int, d.dz::int, (p_tick - c.last_tick)::int, true, k.rot_ch, c.yaw, c.pitch)
                    when k.rot_ch then mc.pkt_move_entity_rot(c.id, c.yaw, c.pitch, true) || mc.pkt_rotate_head(c.id, c.yaw) end as pkt
          from cand c
          cross join lateral (select (c.gx <> 0 or c.gz <> 0) as walking) w
          cross join lateral (select (not w.walking or p_tick - c.every <= c.t0) as first_, p_tick - c.born as tc) f
          cross join lateral (select c.x0 + c.gx * (p_tick - c.t0) as nx, c.z0 + c.gz * (p_tick - c.t0) as nz) n
          cross join lateral (select mc.quant(n.nx) - case when f.first_ then c.sqx else mc.quant(c.x0 + c.gx * (p_tick - c.every - c.t0)) end as dx,
                                     case when f.first_ then mc.quant(c.y) - c.sqy else 0 end as dy,
                                     mc.quant(n.nz) - case when f.first_ then c.sqz else mc.quant(c.z0 + c.gz * (p_tick - c.every - c.t0)) end as dz) d
          cross join lateral (select (d.dx * d.dx + d.dy * d.dy + d.dz * d.dz >= 128 or f.tc % 60 = 0) as pos_ch,
                                     (f.first_ and abs(mc.angle_byte(c.yaw) - mc.angle_byte(c.syaw)) >= 1) as rot_ch,
                                     (abs(d.dx) > 32767 or abs(d.dy) > 32767 or abs(d.dz) > 32767 or f.tc % 400 = 0) as sync) k0
          cross join lateral (select k0.pos_ch, k0.rot_ch, k0.sync, f.first_ and (k0.sync or (w.walking and not k0.pos_ch)) as bad) k
    ), cellblob as materialized (
        -- ONE blob per (chunk cell, tracking range): the packets of all due mobs of the cell, in id order; every viewer of the cell gets the blob once (sql/551)
        select m.cx, m.cz, m.trk, string_agg(m.pkt, '\x'::bytea order by m.id) as blob from main m where m.pkt is not null group by m.cx, m.cz, m.trk
    )
        select (select array_agg(m.id) from main m where m.bad), (select count(*) from main),
           (select array_agg(c.cx) from cellblob c), (select array_agg(c.cz) from cellblob c), (select array_agg(c.trk::int) from cellblob c), (select array_agg(c.blob) from cellblob c)
          into bad, nmain, bcx, bcz, btrk, bblob;

        perform set_config('dbcraft.entity_auto_n', nmain::text, false);
        if bcx is not null then perform mc.entity_fan_cells(bcx, bcz, btrk, bblob); end if;
        perform mc.entity_auto_end(bad, p_tick, p_tick - 1);             -- position of this tick, delta base of the steps before it: the generic tracker takes over
    elsif p_steps then
        perform set_config('dbcraft.entity_auto_n', '0', false);
    end if;
    bad := coalesce(bad, '{}'::int[]);
end $$;

-- The work of one tick.  Returns the ids the generic tracker must handle.  Nothing to do (the common case of a population nobody watches: no eager lane, no lazy lane in its slot with an expired
-- segment): two index probes, no statement.
create or replace function mc.entity_auto_tick(p_tick bigint) returns int[] language plpgsql volatile as $$
declare r record;
begin
    select * into r from mc.entity_auto_run(p_tick, true, null);       -- (it probes what there is to do before it runs a statement)
    -- A lane that is behind by more than one segment (a lazy lane replays ONE segment per visit of its slot, an eager one that was lazy a segment per tick) is not run again in this tick: another pass
    -- costs 0.7 ms of set-up for a handful of rows.  It catches up in its next visits, and at once when somebody is about to look (mc.entity_auto_catchup).
    return r.bad;
end $$;

-- Bring the lanes among p_ids to the state after tick p_to: whoever is about to look at a lane catches it up first.  The entity rows of all of them get the lanes' cells (a lazy lane that crossed
-- a border in its slot left its entity row behind).  Returns how many lanes were behind.
create or replace function mc.entity_auto_catchup(p_to bigint, p_ids int[]) returns int language plpgsql volatile as $$
declare r record; i int := 0; ids int[];
begin
    if p_to is null or p_ids is null then return 0; end if;
    select array_agg(l.id) into ids from mc.entity_lane l where l.auto and l.id = any(p_ids) and l.goal_until <= p_to;
    if ids is not null then
        loop
            select * into r from mc.entity_auto_run(p_to, false, ids);
            i := i + 1;
            exit when r.more = 0 or i >= 5000;
        end loop;
    end if;
    update mc.entity e set cx = l.cx, cz = l.cz, sent_cx = l.cx, sent_cz = l.cz from mc.entity_lane l where l.id = e.id and l.auto and e.id = any(p_ids) and (e.cx <> l.cx or e.cz <> l.cz);
    return coalesce(cardinality(ids), 0);
end $$;

-- the lanes that may be behind (lazy ones: their rows too) whose cell is within p_r chunks of one of the given cells
create or replace function mc.entity_auto_lanes_near(p_to bigint, p_cx int[], p_cz int[], p_r int) returns int[] language sql stable as $$
  select array_agg(l.id) from mc.entity_lane l
   where l.auto and (l.lazy or l.goal_until <= p_to) and exists (select 1 from unnest(p_cx, p_cz) c(x, z) where abs(l.cx - c.x) <= p_r and abs(l.cz - c.z) <= p_r)
$$;

-- a section of a chunk with a floor summary is about to change (the trigger of sql/541 calls this only then: world generation has none): the lanes around it that are behind are replayed first,
-- against the floor as it was (a lane started on that floor)
create or replace function mc.entity_auto_floor_change(p_dim text, p_cx int, p_cz int) returns void language plpgsql volatile as $$
declare lt bigint;
begin
    if mc.entity_mode() = 'split' then return; end if;                                             -- the lanes belong to the other connection
    select c.last_tick into lt from mc.entity_clock c;
    if lt is null then return; end if;
    perform mc.entity_auto_catchup(lt, array(select l.id from mc.entity_lane l where l.auto and l.goal_until <= lt and l.dim = p_dim and abs(l.cx - p_cx) <= 4 and abs(l.cz - p_cz) <= 4));       -- (the lanes within 3 chunks end at a block event, and the cell of a lazy lane may be one behind)
    update mc.entity_lane l set ucx = null, ucz = null, uok = null where l.auto and l.ucx is not null and l.dim = p_dim and abs(l.ucx - p_cx) <= 1 and abs(l.ucz - p_cz) <= 1;      -- the uniform-floor verdicts that include this chunk
end $$;

------------------------------------------------------------------------------------------------ exact current positions (an autonomous lane's position comes from its row)
create or replace view mc.entity_live as
select e.id, e.type, e.dimension,
       case when l.auto then l.x0 + l.gx * greatest(t.t - l.t0, 0) when e.lane_until > 0 then e.x + e.gx * greatest(t.t - e.phys_tick, 0) else e.x end as x, e.y,
       case when l.auto then l.z0 + l.gz * greatest(t.t - l.t0, 0) when e.lane_until > 0 then e.z + e.gz * greatest(t.t - e.phys_tick, 0) else e.z end as z,
       e.on_ground, e.lane_until > 0 as in_lane
  from mc.entity e left join mc.entity_lane l on l.id = e.id and l.auto
  cross join (select coalesce(nullif(current_setting('dbcraft.entity_tick', true), '')::bigint, 0) as t) t;

-- the lanes of sql/541 (chasing mobs) are few: their scans read this index of the legacy rows only, not the whole lane table
create index if not exists entity_lane_legacy_idx on mc.entity_lane (id) where not auto;
-- the two populations of autonomous lanes: the ones somebody may watch (all of them are scanned, filtered by the end of their segment) and the lazy ones (only the slot of the tick: id % 32).
-- The keys never change while a lane lives (a lane row is rewritten at every segment, and with an index on goal_until every rewrite would leave a dead index entry behind that bitmap scans
-- re-check on every tick until the next vacuum): the updates stay HOT.
drop index if exists mc.entity_lane_eager_idx;
drop index if exists mc.entity_lane_dormant_idx;
drop index if exists mc.entity_lane_lazy_idx;
create index if not exists entity_lane_eager_idx on mc.entity_lane (id) where auto and not lazy;
create index if not exists entity_lane_lazy_idx on mc.entity_lane ((id % 32)) where auto and lazy and not dormant;      -- (dormant lanes have no events: never visited)
-- dormant lanes by cell: mc.entity_viewers_refresh wakes the ones within 2 chunks of a viewer's new cell (the update of dormant / lazy is not HOT: it happens when a mob goes dormant or wakes, not per tick)
create index if not exists entity_lane_dormant_idx on mc.entity_lane (cx, cz) where dormant;
-- dropped items by cell: the pickup scan of every player reads the items of its 3x3 cells, not every mob standing there
create index if not exists entity_item_cell_idx on mc.entity (cx, cz) where type = 'minecraft:item';

-- an autonomous lane row is rewritten once per segment (every 50 ticks or so): room for the new version in the page keeps those updates HOT (fillfactor 70 gave 31 % HOT updates, the
-- rest went to the primary-key index as well).  Takes effect for the pages written from now on.
alter table mc.entity_lane set (fillfactor = 50);
