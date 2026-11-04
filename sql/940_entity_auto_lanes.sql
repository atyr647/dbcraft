-- Autonomous entity lanes (docs/PERF-MOBS2.md).  The lanes of sql/541 (dead reckoning for ONE goal, entity row rewritten at every goal, lane row rewritten at every tracker step) become
-- lanes that carry a mob through its whole life on flat ground:
--
--   * the lane row is the complete state of the mob (position anchor, velocity, goal, chunk, delta base): the wide mc.entity row is not read and not written while the lane lasts;
--   * a tracker step (every 3rd tick) writes NOTHING: the packet is a function of the lane row and the tick (the viewers' delta base after a step is the position one step earlier,
--     which the closed form gives; only the FIRST step of a segment reads the stored base);
--   * the next goal is drawn inside the lane (same hash, same distribution as mc.entity_ai_ids) and costs one narrow row update, not a flush + AI + lane-try of the wide row;
--   * the lane ends (the mob goes back to the exact sweep) at the chunk border, when the next goal's footprint is not on a uniform floor, on a block change nearby, or when the
--     tick sequence has a gap (mc.entity_auto_rebase).  mc.entity_auto_end brings the entity row up to date.
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
     and (not exists (select 1 from (values (0), (1), (2)) d(i) cross join (values (0), (1), (2)) d2(i)
                       left join lateral (select f0.top_min, f0.top_max from mc.entity_floor f0
                                           where f0.dimension = p_dim and f0.cx = (x0 >> 4) + d.i and f0.cz = (z0 >> 4) + d2.i offset 0) f on true
                      where (x0 >> 4) + d.i <= (x1 >> 4) and (z0 >> 4) + d2.i <= (z1 >> 4) and (f.top_min is distinct from p_fy - 1 or f.top_max is distinct from p_fy - 1))
          or not exists (select 1 from generate_series(x0, x1) gx(x) cross join generate_series(z0, z1) gz(z)
                          left join lateral (select f1.tops[((gz.z & 15) * 16 + (gx.x & 15)) + 1] as top from mc.entity_floor f1
                                              where f1.dimension = p_dim and f1.cx = gx.x >> 4 and f1.cz = gz.z >> 4 offset 0) f on true
                         where f.top is distinct from (p_fy - 1)))
$$;

------------------------------------------------------------------------------------------------ ending lanes: the entity row gets the state after tick p_pos (position) with the delta base of the steps up to p_base
create or replace function mc.entity_auto_end(p_ids int[], p_pos bigint, p_base bigint) returns int language plpgsql volatile as $$
declare n int;
begin
    if p_ids is null or cardinality(p_ids) = 0 then return 0; end if;
    with u as (
        update mc.entity e set x = l.x0 + l.gx * greatest(p_pos - l.t0, 0), z = l.z0 + l.gz * greatest(p_pos - l.t0, 0), phys_tick = greatest(p_pos, l.t0), lane_until = 0,
               goal_until = l.gend, gx = l.gx, gz = l.gz, vx = l.gx, vz = l.gz, yaw = l.yaw,
               cx = floor((l.x0 + l.gx * greatest(p_pos - l.t0, 0)) / 16)::int, cz = floor((l.z0 + l.gz * greatest(p_pos - l.t0, 0)) / 16)::int,
               sent_qx = b.bx, sent_qy = b."by", sent_qz = b.bz, sent_yaw = b.byaw, last_sent_tick = b.blast
          from (select l0.* from mc.entity_lane l0 where l0.id = any(p_ids) and l0.auto) l
          cross join lateral mc.entity_auto_base(l.t0, l.every, l.slot, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.goal_until, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick, p_base) b
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
declare n int;
begin
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
set enable_hashjoin = off set enable_mergejoin = off as $$
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
               p.update_interval as every, ((e.born_tick % p.update_interval) + p.update_interval)::int % p.update_interval as slot, p.tracking_chunks as trk, p.width / 2 as hw, p.walk_speed as wsp,
               u.lend
          from unnest(ids, lends) u(id, lend) cross join lateral (select e0.* from mc.entity e0 where e0.id = u.id offset 0) e join mc.entity_type_param p on p.type = e.type
    ), ins as (
        insert into mc.entity_lane (id, goal_until, every, slot, chase, sqx, sqy, sqz, syaw, last_tick, auto, t0, x0, z0, y, gx, gz, gend, yaw, pitch, cx, cz, trk, born, hw, wsp, dim, phead)
        select ent.id, ent.lend, ent.every, ent.slot, false, ent.sent_qx, ent.sent_qy, ent.sent_qz, ent.sent_yaw, ent.last_sent_tick, true, ent.phys_tick, ent.x, ent.z, ent.y, ent.gx, ent.gz,
               ent.goal_until, ent.yaw, ent.pitch, ent.cx, ent.cz, ent.trk, ent.born_tick, ent.hw, ent.wsp, ent.dimension,
               (select substring(h from 1 for octet_length(h) - 6) from (select mc.epkt_mob_move(ent.id, 0, 0, 0, ent.every, true, false, 0::real, 0::real) as h) hh)
          from ent
        on conflict (id) do update set goal_until = excluded.goal_until, every = excluded.every, slot = excluded.slot, chase = false, sqx = excluded.sqx, sqy = excluded.sqy, sqz = excluded.sqz,
               syaw = excluded.syaw, last_tick = excluded.last_tick, auto = true, t0 = excluded.t0, x0 = excluded.x0, z0 = excluded.z0, y = excluded.y, gx = excluded.gx, gz = excluded.gz,
               gend = excluded.gend, yaw = excluded.yaw, pitch = excluded.pitch, cx = excluded.cx, cz = excluded.cz, trk = excluded.trk, born = excluded.born, hw = excluded.hw, wsp = excluded.wsp, dim = excluded.dim,
               phead = excluded.phead
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

------------------------------------------------------------------------------------------------ one tick of all autonomous lanes (ONE scan of the lane table, ONE statement)
-- For the lanes whose segment ends now (goal over, or the position is outside the cell) and the lanes whose tracker step is due now:
--   * segment over:   the goal is drawn if it is over (mc.entity_goal, the hash of mc.entity_ai_ids), else kept.  The lane goes on in a NEW SEGMENT (one row update: anchor moved to the
--                     end of tick p_tick - 1, the viewers' base stored, the cell of the position at p_tick) if the next walk's footprint is on a uniform floor and, when the cell changes,
--                     the viewers of the two cells are the same (a border crossing nobody notices; the entity row gets the new cell).  Otherwise the lane ENDS: the entity row gets the state
--                     after tick p_tick - 1 and the goal (the new one if it was drawn: the AI of this tick is done), and the exact sweep simulates the mob from now on.
--   * step due:       the packet from the lane row alone: head || dx || 0 || dz.  The first step of a segment reads the stored base; a first step that cannot be expressed this way
--                     (position sync tick, delta over a short, a walk whose first step does not move) ends the lane and is returned for the generic tracker.
-- Returns the ids that the generic tracker must handle this tick.
create or replace function mc.entity_auto_tick(p_tick bigint) returns int[] language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off as $$
declare wp float8 := coalesce(nullif(current_setting('dbcraft.entity_walk_prob', true), '')::float8, 0.6);
        ex int[]; bad int[]; nmain int; bcx int[]; bcz int[]; btrk int[]; bblob bytea[];
begin
    with s as materialized (
        select l.id, l.goal_until, l.every, l.slot, l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick, l.t0, l.x0, l.z0, l.y, l.gx, l.gz, l.gend, l.yaw, l.pitch, l.cx, l.cz, l.trk, l.born, l.hw, l.wsp,
               l.dim, l.phead, (l.goal_until <= p_tick) as ended
          from mc.entity_lane l
         where l.auto and l.goal_until <= p_tick
    ), g as materialized (
        -- the segment is over: the goal (new if it ran out) and the state at the end of tick p_tick - 1 (anchor of the next segment, delta base of the viewers)
        select s.id, s.every, s.slot, s.y, s.pitch, s.cx as ocx, s.cz as ocz, s.trk, s.born, s.hw, s.wsp, s.dim, s.phead, (s.gend <= p_tick) as expired,
               case when s.gend <= p_tick then ng.gx else s.gx end as ngx, case when s.gend <= p_tick then ng.gz else s.gz end as ngz,
               case when s.gend <= p_tick then p_tick + ng.dur else s.gend end as ngend, case when s.gend <= p_tick then ng.yaw else s.yaw end as nyaw,
               s.x0 + s.gx * greatest(p_tick - 1 - s.t0, 0) as ax, s.z0 + s.gz * greatest(p_tick - 1 - s.t0, 0) as az,
               b.bx, b."by", b.bz, b.byaw, b.blast
          from s
          left join lateral mc.entity_goal(s.id, p_tick, s.yaw, s.wsp, wp) ng on s.gend <= p_tick
          cross join lateral mc.entity_auto_base(s.t0, s.every, s.slot, s.x0, s.z0, s.y, s.gx, s.gz, s.yaw, s.goal_until, s.born, s.sqx, s.sqy, s.sqz, s.syaw, s.last_tick, p_tick - 1) b
         where s.ended
    ), w as materialized (
        -- the cell of the position at tick p_tick and the end of the next segment (goal end or first tick outside that cell)
        select g.*, floor((g.ax + g.ngx) / 16)::int as ncx, floor((g.az + g.ngz) / 16)::int as ncz from g
    ), w2 as materialized (
        select w.*, least(w.ngend, (p_tick - 1) + least(mc.entity_cell_exit(w.ax, w.ngx, w.ncx), mc.entity_cell_exit(w.az, w.ngz, w.ncz))) as nlend from w
    ), v as materialized (
        select w2.*, (w2.ncx <> w2.ocx or w2.ncz <> w2.ocz) as crossing,
               w2.nlend > p_tick and (
                   (w2.ngx = 0 and w2.ngz = 0)
                   or (sqrt(w2.ngx * w2.ngx + w2.ngz * w2.ngz) * w2.every * 4096 between 40 and 30000 and abs(w2.ngx) * w2.every * 4096 < 30000 and abs(w2.ngz) * w2.every * 4096 < 30000
                       and mc.entity_floor_ok(w2.dim, floor(w2.y)::int,
                                              floor(least(w2.ax, w2.ax + w2.ngx * (w2.nlend - (p_tick - 1))) - w2.hw - 1e-6)::int, floor(greatest(w2.ax, w2.ax + w2.ngx * (w2.nlend - (p_tick - 1))) + w2.hw + 1e-6)::int,
                                              floor(least(w2.az, w2.az + w2.ngz * (w2.nlend - (p_tick - 1))) - w2.hw - 1e-6)::int, floor(greatest(w2.az, w2.az + w2.ngz * (w2.nlend - (p_tick - 1))) + w2.hw + 1e-6)::int)))
               and ((w2.ncx = w2.ocx and w2.ncz = w2.ocz) or mc.entity_view_same(w2.ocx, w2.ocz, w2.ncx, w2.ncz, w2.trk)) as ok
          from w2
    ), upd as (
        -- every lane whose segment ended gets its anchor and goal moved (a lane that must end carries the new goal into its entity row)
        update mc.entity_lane l set goal_until = case when v.ok then v.nlend else p_tick end, t0 = p_tick - 1, x0 = v.ax, z0 = v.az, gx = v.ngx, gz = v.ngz, gend = v.ngend, yaw = v.nyaw,
               sqx = v.bx, sqy = v."by", sqz = v.bz, syaw = v.byaw, last_tick = v.blast, cx = case when v.ok then v.ncx else l.cx end, cz = case when v.ok then v.ncz else l.cz end
          from v where l.id = v.id returning l.id
    ), upe as (
        -- the mobs that crossed a border without anybody noticing: their entity row carries the cell (viewers refresh, despawn and the generic tracker read it)
        update mc.entity e set cx = v.ncx, cz = v.ncz, sent_cx = v.ncx, sent_cz = v.ncz from v where e.id = v.id and v.ok and v.crossing returning e.id
    ), cand as (
        -- the lanes that step in this tick: those whose segment goes on (straight from the table) and those that just started a new segment (from v); streamed, nothing is copied
        select l.id, l.cx, l.cz, l.trk, l.every, l.t0, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.pitch, l.phead, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick
          from mc.entity_lane l
         where l.auto and l.goal_until > p_tick and case when l.gx <> 0 or l.gz <> 0 then l.slot = (p_tick % l.every)::int else p_tick = l.t0 + 1 end
        union all
        select v.id, v.ncx, v.ncz, v.trk, v.every, p_tick - 1, v.ax, v.az, v.y, v.ngx, v.ngz, v.nyaw, v.pitch, v.phead, v.born, v.bx, v."by", v.bz, v.byaw, v.blast
          from v where v.ok and case when v.ngx <> 0 or v.ngz <> 0 then v.slot = (p_tick % v.every)::int else true end
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
    select (select array_agg(v.id) from v where not v.ok),
           (select array_agg(m.id) from main m where m.bad), (select count(*) from main),
           (select array_agg(c.cx) from cellblob c), (select array_agg(c.cz) from cellblob c), (select array_agg(c.trk::int) from cellblob c), (select array_agg(c.blob) from cellblob c)
      into ex, bad, nmain, bcx, bcz, btrk, bblob;
    perform set_config('dbcraft.entity_auto_n', nmain::text, false);
    if bcx is not null then perform mc.entity_fan_cells(bcx, bcz, btrk, bblob); end if;
    perform mc.entity_auto_end(ex, p_tick - 1, p_tick - 1);          -- (their goal was drawn above, or kept)
    perform mc.entity_auto_end(bad, p_tick, p_tick - 1);              -- position of this tick, delta base of the steps before it: the generic tracker takes over
    return coalesce(bad, '{}'::int[]);
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
-- dropped items by cell: the pickup scan of every player reads the items of its 3x3 cells, not every mob standing there
create index if not exists entity_item_cell_idx on mc.entity (cx, cz) where type = 'minecraft:item';

-- an autonomous lane row is rewritten once per segment (every 50 ticks or so): room for the new version in the page keeps those updates HOT (fillfactor 70 gave 31 % HOT updates, the
-- rest went to the primary-key index as well).  Takes effect for the pages written from now on.
alter table mc.entity_lane set (fillfactor = 50);
