-- Entity LANES: analytic (dead-reckoned) movement for walking mobs.  See docs/PERF-ENTITY.md.
--
-- A walking mob on a flat floor does not need the collision sweep every tick: while its goal lasts, nothing it can touch changes, so its position is a closed-form
-- function of the tick.  A LANE is the promise "from the state after tick phys_tick until tick lane_until the mob walks at (gx, gz) on the floor it stands on":
--
--     x(t) = x + gx * (t - phys_tick)        z(t) = z + gz * (t - phys_tick)        y, on_ground unchanged, vy = 0
--
-- The promise is checked ONCE per goal, not once per tick: the footprint of the whole walk (the bounding box of the start and end positions plus the entity width)
-- must lie in chunks whose floor is UNIFORM, i.e. every column of the chunk has its highest solid cell exactly one below the entity's feet (mc.entity_floor, a cache built
-- from the same solidity masks the sweep uses, so it is exact for the model, not a heightmap approximation).  Then no solid cell can be in the way (nothing is solid above
-- the highest solid cell of a column) and the floor under every step is solid: the sweep would return exactly "free horizontal move, vertical move clipped to 0".
-- Anything else (a block placed in the way, a goal change, non-uniform terrain, a chunk that is not generated) ends the lane and the exact sweep takes over again.
--
-- Rows stay readable and fresh: a lane entity's row is rewritten at the tracker's sampling cadence (every 3 ticks for mobs) instead of every tick, so x/z are never more
-- than update_interval ticks behind; the view mc.entity_live gives the exact current position of every entity.
--
-- The lane position is the DEFINITION for lane mobs (closed form), not an approximation of the iterated sweep: iterated, the sweep rounds ((x - hw) + gx) + hw per tick;
-- the two agree to about 1e-12 blocks (tests/sql/541), far below the 1/4096 block quantisation of the network protocol.  Mob speeds are approximate in this prototype anyway.

alter table mc.entity add column if not exists lane_until bigint not null default 0;     -- 0: no lane; otherwise the lane is valid for ticks < lane_until
-- The lane bookkeeping lives in its own small table (one row per lane, about as many rows as there are walking mobs), NOT in indexes of mc.entity: the two scans the
-- tick needs every tick (lanes whose goal ran out / chasers on their re-aim phase, and lane mobs the tracker samples this tick) read the whole table, which costs a fraction
-- of a millisecond whatever the statistics say.  Partial indexes on mc.entity were tried first: statistics collected while no lane existed made the planner pick the wrong
-- index and scan 1,000 entries to find 60 (30 ms instead of 0.3).
create table if not exists mc.entity_lane (
    id         int primary key references mc.entity(id) on delete cascade,       -- a lane row never outlives its entity (despawn, pickup, deletes: the cascade removes it)
    goal_until bigint not null,                  -- the lane ends at this tick (the goal's end, or earlier: before the entity's centre would leave its chunk)
    every      smallint not null,                -- tracker update interval of the type and the phase of the entity in it (born_tick mod interval)
    slot       smallint not null,
    chase      boolean not null,                 -- zombies re-aim every 5th tick (by id), which ends their lane
    -- what the viewers were last told (the tracker's delta base, like mc.entity.sent_*): kept HERE while the entity is in a lane (a narrow row instead of the wide entity row)
    -- and written back to mc.entity when the lane ends
    sqx bigint not null default 0, sqy bigint not null default 0, sqz bigint not null default 0, syaw real not null default 0, last_tick bigint not null default 0
) with (fillfactor = 70);
alter table mc.entity_lane add column if not exists auto boolean not null default false;     -- autonomous lane (sql/940); false: the lanes of this file (chasing mobs)
-- the table is scanned every tick and churns (lanes start and end constantly): vacuum it early and often so a quiet world never scans dead pages
alter table mc.entity_lane set (autovacuum_vacuum_threshold = 200, autovacuum_vacuum_scale_factor = 0) ;
drop index if exists mc.entity_lane_goal_idx; drop index if exists mc.entity_lane_chase_idx; drop index if exists mc.entity_lane_slot_idx; drop index if exists mc.entity_lane_idx;
alter table mc.entity drop column if exists trk_every; alter table mc.entity drop column if exists trk_slot;
create index if not exists entity_awake_nolane_idx on mc.entity (id) where not deep_sleep and lane_until = 0;                      -- the physics step reads only the entities outside lanes
drop index if exists mc.entity_awake_idx;                                                                                          -- replaced by the one above

-- Per chunk: the lowest and highest "highest solid y" over its 256 columns.  NULL: not uniform / unknown (a column without any solid cell, or no chunk).  A cache: deleted
-- when a section of the chunk changes (the trigger below), rebuilt lazily when a lane is wanted.
create unlogged table if not exists mc.entity_floor (
    dimension text not null, cx int not null, cz int not null,
    top_min int, top_max int,
    tops smallint[],                -- the highest solid y of each of the 256 columns, index (z & 15) * 16 + (x & 15) + 1; -32768: no solid cell in the column
    primary key (dimension, cx, cz)
) with (fillfactor = 90);
alter table mc.entity_floor add column if not exists tops smallint[];

create or replace function mc.entity_floor_build(p_dim text, p_cx int, p_cz int) returns void language plpgsql volatile as $$
declare tmin int; tmax int; cnt int; r record; tops smallint[];
begin
    for r in select s.sy from mc.chunk_section s
              where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz
                and not exists (select 1 from mc.solid_mask m where m.dimension = s.dimension and m.cx = s.cx and m.cz = s.cz and m.sy = s.sy) loop
        perform mc.entity_build_mask(p_dim, p_cx, p_cz, r.sy);
    end loop;
    -- bit k of a mask is the cell (y = k >> 8, z = (k >> 4) & 15, x = k & 15), the wire order
    select min(q.t), max(q.t), count(*) into tmin, tmax, cnt
      from (select k & 15 as x, (k >> 4) & 15 as z, max(m.sy * 16 + (k >> 8)) as t
              from mc.solid_mask m cross join lateral generate_series(0, 4095) k
             where m.dimension = p_dim and m.cx = p_cx and m.cz = p_cz and m.solid_cnt > 0 and get_bit(m.mask, k) = 1
             group by 1, 2) q;
    select array_agg(coalesce(c.t, -32768)::smallint order by g.k) into tops
      from generate_series(0, 255) g(k)
      left join (select (k & 15) + ((k >> 4) & 15) * 16 as col, max(m.sy * 16 + (k >> 8)) as t
                   from mc.solid_mask m cross join lateral generate_series(0, 4095) k
                  where m.dimension = p_dim and m.cx = p_cx and m.cz = p_cz and m.solid_cnt > 0 and get_bit(m.mask, k) = 1
                  group by 1) c on c.col = g.k;
    insert into mc.entity_floor (dimension, cx, cz, top_min, top_max, tops)
    values (p_dim, p_cx, p_cz, case when cnt = 256 then tmin end, case when cnt = 256 then tmax end, tops)
    on conflict (dimension, cx, cz) do update set top_min = excluded.top_min, top_max = excluded.top_max, tops = excluded.tops;
end $$;

-- the mask invalidation (sql/510) also drops the floor summary of the chunk
create or replace function mc.entity_mask_invalidate() returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        -- a floor summary that lanes may stand on: the lanes around that are behind are replayed against the floor as it was first (sql/940)
        if exists (select 1 from mc.entity_floor f where f.dimension = old.dimension and f.cx = old.cx and f.cz = old.cz) then perform mc.entity_auto_floor_change(old.dimension, old.cx, old.cz); end if;
        delete from mc.solid_mask where dimension = old.dimension and cx = old.cx and cz = old.cz and sy = old.sy;
        delete from mc.entity_floor where dimension = old.dimension and cx = old.cx and cz = old.cz;
    else
        if exists (select 1 from mc.entity_floor f where f.dimension = new.dimension and f.cx = new.cx and f.cz = new.cz) then perform mc.entity_auto_floor_change(new.dimension, new.cx, new.cz); end if;
        delete from mc.solid_mask where dimension = new.dimension and cx = new.cx and cz = new.cz and sy = new.sy;
        delete from mc.entity_floor where dimension = new.dimension and cx = new.cx and cz = new.cz;
    end if;
    return null;
end $$;

-- the physics step skips entities that walk in a lane
create or replace function mc.entity_active(p_tick bigint)
returns table (id int, dimension text, x float8, y float8, z float8, vx float8, vy float8, vz float8, on_ground boolean, hw float8, h float8, kind text, cx int, cz int, gx float8, gz float8)
language sql stable parallel safe as $$
  select e.id, e.dimension, e.x, e.y, e.z,
         case when p.kind = 'mob' then e.gx else e.vx end,
         e.vy - p.gravity * (p_tick - e.phys_tick),
         case when p.kind = 'mob' then e.gz else e.vz end,
         e.on_ground, p.width / 2, p.height, p.kind, e.cx, e.cz, e.gx, e.gz
  from mc.entity e join mc.entity_type_param p on p.type = e.type
  where not e.deep_sleep and e.lane_until = 0       -- the flush at the start of the tick leaves lane_until = 0 or a future tick
    and (p.kind = 'mob'
         or not (e.on_ground and e.vx * e.vx + e.vz * e.vz <= 9.999999747378752e-06)
         or (p_tick - e.born_tick + e.id) % 4 = 0)
$$;

create or replace function mc.entity_lanes_enabled() returns boolean language sql stable as $$ select coalesce(current_setting('dbcraft.entity_lanes', true), 'on') <> 'off' $$;
-- autonomous lanes (sql/940) carry every mob that does not chase; with dbcraft.entity_auto = 'off' everybody uses the lanes of this file
create or replace function mc.entity_auto_enabled() returns boolean language sql stable as $$ select coalesce(current_setting('dbcraft.entity_auto', true), 'on') <> 'off' $$;

-- The mobs that may start a lane now: standing on the ground, at rest vertically, y exactly an integer (the top of a full cube), walking, with at least two ticks of goal left.
-- The footprint chunks are those the bounding box of the whole walk (start to the position at the end of the goal, plus the entity width) touches.
drop function if exists mc.entity_lane_cand(bigint, int[]);
create or replace function mc.entity_lane_cand(p_tick bigint, p_ids int[])
returns table (id int, dimension text, fy int, lend bigint, cx0 int, cx1 int, cz0 int, cz1 int, every int, slot int, x0 int, x1 int, z0 int, z1 int) language sql stable as $$
  select c.id, c.dimension, c.fy, c.lend, c.x0 >> 4, c.x1 >> 4, c.z0 >> 4, c.z1 >> 4, c.every, c.slot, c.x0, c.x1, c.z0, c.z1
    from (select q.id, q.dimension, q.fy, q.lend, q.every, q.slot,
                 floor(least(q.x, q.x + q.gx * (q.lend - q.phys_tick)) - q.hw - 1e-6)::int as x0, floor(greatest(q.x, q.x + q.gx * (q.lend - q.phys_tick)) + q.hw + 1e-6)::int as x1,
                 floor(least(q.z, q.z + q.gz * (q.lend - q.phys_tick)) - q.hw - 1e-6)::int as z0, floor(greatest(q.z, q.z + q.gz * (q.lend - q.phys_tick)) + q.hw + 1e-6)::int as z1
            from (select e.id, e.dimension, floor(e.y)::int as fy, e.x, e.z, e.gx, e.gz, e.phys_tick, p.width / 2 as hw, p.update_interval as every,
                         ((e.born_tick % p.update_interval) + p.update_interval)::int % p.update_interval as slot,
                         -- the lane ends with the goal, or one tick before the centre would be in another chunk (so cx, cz, and with them who sees the entity, stay exact for the whole lane)
                         least(e.goal_until,
                               e.phys_tick + case when e.gx > 0 then least(ceil((16 * (e.cx + 1) - e.x) / e.gx), 1000000)::bigint when e.gx < 0 then least(floor((e.x - 16 * e.cx) / -e.gx), 1000000)::bigint + 1 else 1000000 end - 1,
                               e.phys_tick + case when e.gz > 0 then least(ceil((16 * (e.cz + 1) - e.z) / e.gz), 1000000)::bigint when e.gz < 0 then least(floor((e.z - 16 * e.cz) / -e.gz), 1000000)::bigint + 1 else 1000000 end - 1) as lend
                    from (select distinct i from unnest(p_ids) i) u(id)
                    cross join lateral (select e0.* from mc.entity e0 where e0.id = u.id offset 0) e         -- offset 0: one primary-key probe per id (the planner scanned the goal index instead)
                    join mc.entity_type_param p on p.type = e.type
                   where p.kind = 'mob' and (p.can_chase or not mc.entity_auto_enabled()) and e.on_ground and not e.deep_sleep and e.lane_until = 0 and e.vy = 0
                     and (e.gx <> 0 or e.gz <> 0) and e.y = floor(e.y)
                     and e.last_sent_tick > 0 and e.sent_cx = e.cx and e.sent_cz = e.cz and e.pitch = e.sent_pitch and e.cx = floor(e.x / 16)::int and e.cz = floor(e.z / 16)::int) q
           where q.lend > p_tick + 1) c
$$;

-- Start lanes for the candidates among p_ids whose whole footprint lies on uniform floors at their feet level.  Returns how many started.
create or replace function mc.entity_lane_try(p_tick bigint, p_ids int[]) returns int language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off set plan_cache_mode = force_generic_plan as $$
declare n int := 0; ids int[]; gus bigint[]; evs int[]; sls int[];
begin
    if p_ids is null or cardinality(p_ids) = 0 or not mc.entity_lanes_enabled() then return 0; end if;
    -- A walk spans at most 3x3 chunks (a goal lasts at most 80 ticks: about 11 blocks); a (values (0),(1),(2)) expansion keeps the row estimates exact
    -- (generate_series is estimated at 1,000 rows, which sent the planner into nested loops over the whole entity table).
    -- floor summaries that do not exist yet (one build per chunk, then cached)
    perform mc.entity_floor_build(m.dimension, m.cx, m.cz)
       from (select distinct c.dimension, c.cx0 + d.i as cx, c.cz0 + d2.i as cz
               from mc.entity_lane_cand(p_tick, p_ids) c, (values (0), (1), (2)) d(i), (values (0), (1), (2)) d2(i)
              where c.cx1 - c.cx0 <= 2 and c.cz1 - c.cz0 <= 2 and c.cx0 + d.i <= c.cx1 and c.cz0 + d2.i <= c.cz1
                and not exists (select 1 from mc.entity_floor f where f.dimension = c.dimension and f.cx = c.cx0 + d.i and f.cz = c.cz0 + d2.i and f.tops is not null)
              order by 1, 2, 3 limit 8) m;      -- at most 8 floor builds (about 1.7 ms each) per call: mobs in chunks not summarised yet take the exact sweep and get their lane a tick later
    -- Valid when every column the walk covers has its highest solid cell exactly under the feet.  Fast path: all footprint chunks are uniform at that level (two integer
    -- comparisons per chunk).  Otherwise the columns are checked one by one against the chunk's column table: a flat patch inside a bumpy chunk still qualifies.
    select array_agg(q.id), array_agg(q.lend), array_agg(q.every), array_agg(q.slot) into ids, gus, evs, sls
      from (select c.id, c.lend, c.every, c.slot
              from mc.entity_lane_cand(p_tick, p_ids) c
             where c.cx1 - c.cx0 <= 2 and c.cz1 - c.cz0 <= 2
               and (not exists (select 1 from (values (0), (1), (2)) d(i) cross join (values (0), (1), (2)) d2(i)
                                 left join lateral (select f0.top_min, f0.top_max from mc.entity_floor f0
                                                     where f0.dimension = c.dimension and f0.cx = c.cx0 + d.i and f0.cz = c.cz0 + d2.i offset 0) f on true
                                where c.cx0 + d.i <= c.cx1 and c.cz0 + d2.i <= c.cz1 and (f.top_min is distinct from c.fy - 1 or f.top_max is distinct from c.fy - 1))
                    or not exists (select 1 from generate_series(c.x0, c.x1) gx(x) cross join generate_series(c.z0, c.z1) gz(z)
                                    left join lateral (select f1.tops[((gz.z & 15) * 16 + (gx.x & 15)) + 1] as top from mc.entity_floor f1
                                                        where f1.dimension = c.dimension and f1.cx = gx.x >> 4 and f1.cz = gz.z >> 4 offset 0) f on true
                                   where f.top is distinct from (c.fy - 1)))) q;
    if ids is null then return 0; end if;
    insert into mc.entity_lane (id, goal_until, every, slot, chase, sqx, sqy, sqz, syaw, last_tick)
    select u.id, u.gu, u.ev, u.sl, e.type = 'minecraft:zombie', e.sent_qx, e.sent_qy, e.sent_qz, e.sent_yaw, e.last_sent_tick
      from unnest(ids, gus, evs, sls) u(id, gu, ev, sl) join mc.entity e on e.id = u.id
    on conflict (id) do update set goal_until = excluded.goal_until, every = excluded.every, slot = excluded.slot, chase = excluded.chase,
                                   sqx = excluded.sqx, sqy = excluded.sqy, sqz = excluded.sqz, syaw = excluded.syaw, last_tick = excluded.last_tick;
    update mc.entity e set lane_until = u.gu, vx = e.gx, vz = e.gz, vy = 0 from unnest(ids, gus) u(id, gu) where e.id = u.id;      -- the walk velocity: what a position sync would carry
    get diagnostics n = row_count;
    return n;
end $$;

-- End the lanes of the mobs the AI is about to give a new goal (goal expired) or re-aim (zombies on their chase phase): their rows are brought up to the state after tick p_tick - 1.
-- Returns the ids (they may start a new lane right away).
create or replace function mc.entity_lane_flush(p_tick bigint) returns int[] language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off as $$
declare ids int[]; due int[];
begin
    select coalesce(array_agg(l.id), '{}') into due from mc.entity_lane l
     where not l.auto and (l.goal_until <= p_tick or (l.chase and l.id % 5 = ((5 - p_tick % 5) % 5)::int));
    if cardinality(due) = 0 then return '{}'; end if;
    -- the row is brought up to the state after tick p_tick - 1 and gets back what the viewers were last told (kept in the lane row during the lane)
    with u as (update mc.entity e set x = e.x + e.gx * ((p_tick - 1) - e.phys_tick), z = e.z + e.gz * ((p_tick - 1) - e.phys_tick), phys_tick = p_tick - 1, lane_until = 0,
                      cx = floor((e.x + e.gx * ((p_tick - 1) - e.phys_tick)) / 16)::int, cz = floor((e.z + e.gz * ((p_tick - 1) - e.phys_tick)) / 16)::int,
                      sent_qx = l.sqx, sent_qy = l.sqy, sent_qz = l.sqz, sent_yaw = l.syaw, last_sent_tick = l.last_tick
                 from unnest(due) d(id) join mc.entity_lane l on l.id = d.id where e.id = d.id and e.lane_until > 0 returning e.id)
    select coalesce(array_agg(id), '{}') into ids from u;
    delete from mc.entity_lane where id = any(due);
    return ids;
end $$;

-- Switching lanes off at run time (dbcraft.entity_lanes = 'off'): everybody leaves their lane, exactly at the state after tick p_tick - 1.
create or replace function mc.entity_lane_flush_all(p_tick bigint) returns int language plpgsql volatile as $$
declare n int; m int;
begin
    m := mc.entity_auto_end(array(select a.id from mc.entity_lane a where a.auto), p_tick - 1, p_tick - 1);       -- autonomous lanes (sql/940)
    update mc.entity e set x = e.x + e.gx * greatest((p_tick - 1) - e.phys_tick, 0), z = e.z + e.gz * greatest((p_tick - 1) - e.phys_tick, 0), phys_tick = greatest(p_tick - 1, e.phys_tick), lane_until = 0,
           cx = floor((e.x + e.gx * greatest((p_tick - 1) - e.phys_tick, 0)) / 16)::int, cz = floor((e.z + e.gz * greatest((p_tick - 1) - e.phys_tick, 0)) / 16)::int,
           sent_qx = l.sqx, sent_qy = l.sqy, sent_qz = l.sqz, sent_yaw = l.syaw, last_sent_tick = l.last_tick
      from mc.entity_lane l where e.id = l.id and e.lane_until > 0 and not l.auto;
    get diagnostics n = row_count;
    n := n + coalesce(m, 0);
    delete from mc.entity_lane;
    update mc.entity set lane_until = 0 where lane_until > 0;      -- (lane rows of entities that no longer exist were deleted above; this catches rows without a lane row)
    return n;
end $$;

-- One tracker step for the lane mobs that are due this tick (their slot in the update interval): bring the rows up to date (state after tick p_tick), build the plain movement packets,
-- fan them out to the viewers of the entity's cell, and keep the delta base in the lane row.  The rare cases the generic tracker must handle (a position sync: every 400 ticks, or a
-- delta that does not fit a short) end the lane of that entity and are returned: the caller passes them to mc.entity_tracker like the physics ids.
-- The rules are those of mc.entity_tracker for mobs (stepped delta, no tracked velocity): position packet if the quantised delta squared is >= 128 or every 60 ticks, rotation packet
-- (with the head) if the angle byte changed, packets for one viewer concatenated in one play_out row.
create or replace function mc.entity_lane_step(p_tick bigint) returns int[] language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off as $$
declare due int[]; sync_ids int[];
begin
    select coalesce(array_agg(l.id), '{}') into due from mc.entity_lane l where l.slot = (p_tick % l.every)::int and l.goal_until > p_tick;
    if cardinality(due) = 0 then return '{}'; end if;
    with cur as materialized (
        select e.id, e.cx, e.cz, e.y, e.yaw, e.pitch, e.on_ground, p.tracking_chunks as trk, (p_tick - e.born_tick) as tc,
               e.x + e.gx * (p_tick - e.phys_tick) as nx, e.z + e.gz * (p_tick - e.phys_tick) as nz,
               l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick
          from unnest(due) d(id)
          join mc.entity e on e.id = d.id and e.lane_until > p_tick and e.phys_tick < p_tick
          join mc.entity_lane l on l.id = d.id
          join mc.entity_type_param p on p.type = e.type
    ), calc as materialized (
        select q.*, (q.dx * q.dx + q.dy * q.dy + q.dz * q.dz >= 128 or q.tc % 60 = 0) as pos_ch,
               (abs(mc.angle_byte(q.yaw) - mc.angle_byte(q.syaw)) >= 1) as rot_ch,
               (abs(q.dx) > 32767 or abs(q.dy) > 32767 or abs(q.dz) > 32767 or q.tc % 400 = 0) as sync
          from (select cur.*, mc.quant(cur.nx) as qx, mc.quant(cur.y) as qy, mc.quant(cur.nz) as qz,
                       mc.quant(cur.nx) - cur.sqx as dx, mc.quant(cur.y) - cur.sqy as dy, mc.quant(cur.nz) - cur.sqz as dz from cur) q
    ), pk as materialized (
        select c.id, c.cx, c.cz, c.trk,
               case when c.pos_ch then mc.epkt_mob_move(c.id, c.dx::int, c.dy::int, c.dz::int, (p_tick - c.last_tick)::int, c.on_ground, c.rot_ch, c.yaw, c.pitch)
                    else mc.pkt_move_entity_rot(c.id, c.yaw, c.pitch, c.on_ground) || mc.pkt_rotate_head(c.id, c.yaw) end as pkt
          from calc c where not c.sync and (c.pos_ch or c.rot_ch)
    ), fan as (
        insert into mc.play_out (conn_id, data)
        select v.conn_id, string_agg(pk.pkt, '\x'::bytea order by pk.id)
          from pk cross join lateral (select vv.conn_id from mc.entity_cell_viewer vv where vv.cx = pk.cx and vv.cz = pk.cz offset 0) v
          join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - pk.cx), abs(vc.cz - pk.cz)) <= pk.trk
         group by v.conn_id order by v.conn_id returning 1
    ), ul as (
        update mc.entity_lane l set sqx = case when c.pos_ch then c.qx else l.sqx end, sqy = case when c.pos_ch then c.qy else l.sqy end,
               sqz = case when c.pos_ch then c.qz else l.sqz end, syaw = case when c.rot_ch then c.yaw else l.syaw end,
               last_tick = case when c.pos_ch then p_tick else l.last_tick end
          from calc c where l.id = c.id and not c.sync returning l.id
    ), dl as (
        delete from mc.entity_lane l using calc c where l.id = c.id and c.sync returning l.id
    ), ue as (
        -- the entity row is NOT rewritten while the lane lasts (x, z, phys_tick, gx, gz fix the position for the whole lane; mc.entity_live gives it); only a position sync
        -- ends the lane and brings the row up to date for the generic tracker
        update mc.entity e set x = c.nx, z = c.nz, phys_tick = p_tick, lane_until = 0,
               sent_qx = c.sqx, sent_qy = c.sqy, sent_qz = c.sqz, sent_yaw = c.syaw, last_sent_tick = c.last_tick
          from calc c where e.id = c.id and c.sync returning e.id, c.sync
    )
    select coalesce(array_agg(ue.id), '{}') into sync_ids from ue;
    return sync_ids;
end $$;

-- Block changes: lane mobs near a changed block leave their lane (the next goal check, or the exact sweep this very tick, decides again).
create or replace function mc.entity_wake_on_block_event() returns trigger language plpgsql as $$
declare t bigint; lt bigint;
begin
    select game_time into t from mc.game_state limit 1;
    lt := coalesce(nullif(current_setting('dbcraft.entity_tick', true), '')::bigint, t);          -- the last entity tick: lane rows are valid for the state after it
    update mc.entity e set deep_sleep = false,
           phys_tick = case when e.type = 'minecraft:item' then t - ((t - e.born_tick + e.id) % 4) else t end
      from (select distinct dimension, x, y, z from new_ev) ev
     where e.deep_sleep and e.dimension = ev.dimension
       and e.cx in ((ev.x - 1) >> 4, ev.x >> 4, (ev.x + 1) >> 4) and e.cz in ((ev.z - 1) >> 4, ev.z >> 4, (ev.z + 1) >> 4)
       and abs(floor(e.x)::int - ev.x) <= 1 and abs(floor(e.z)::int - ev.z) <= 1 and floor(e.y)::int - ev.y between -1 and 2;
    -- lanes: everything with a lane in the chunks around the event (a lane can be up to a goal long, about 11 blocks, so one chunk of margin is enough)
    with u as (update mc.entity e set x = e.x + e.gx * greatest(lt - e.phys_tick, 0), z = e.z + e.gz * greatest(lt - e.phys_tick, 0), phys_tick = greatest(lt, e.phys_tick), lane_until = 0,
                      cx = floor((e.x + e.gx * greatest(lt - e.phys_tick, 0)) / 16)::int, cz = floor((e.z + e.gz * greatest(lt - e.phys_tick, 0)) / 16)::int,
                      sent_qx = l0.sqx, sent_qy = l0.sqy, sent_qz = l0.sqz, sent_yaw = l0.syaw, last_sent_tick = l0.last_tick
                 from (select distinct dimension, x >> 4 as ecx, z >> 4 as ecz from new_ev) ev, mc.entity_lane l0
                where l0.id = e.id and e.lane_until > 0 and e.dimension = ev.dimension and e.cx between ev.ecx - 2 and ev.ecx + 2 and e.cz between ev.ecz - 2 and ev.ecz + 2 returning e.id)
    delete from mc.entity_lane l using u where l.id = u.id;
    return null;
end $$;

-- The AI of sql/520 returning the ids it touched (so they can start lanes in the same tick).
create or replace function mc.entity_ai_ids(p_tick bigint) returns int[] language plpgsql volatile as $$
declare a int[]; b int[]; wp float8 := coalesce(nullif(current_setting('dbcraft.entity_walk_prob', true), '')::float8, 0.6);     -- share of new goals that are walks (the rest: stand still); benchmarks set 1.0
begin
    a := '{}'; b := '{}';
    if not exists (select 1 from mc.entity e where e.goal_until > 0 and e.goal_until <= p_tick) then null;      -- nothing expired (one probe of the partial index entity_goal_idx)
    elsif mc.entity_ai_vanilla() then
        -- vanilla-like rates (sql/942): the goal is a wait (2 * Geometric(1/60) ticks, evaluated every second tick) followed by a decision: a stroll to a random block within +-10 if a player is
        -- within 32 blocks, nothing (dormant: goal_until = 2^62, no events) if no player is within 2 chunks
        with u as (
            update mc.entity e set gx = g.gx, gz = g.gz, goal_until = case when g.dorm then 4611686018427387904 else p_tick + g.dur end, yaw = g.yaw, deep_sleep = false,
                                   phys_tick = case when e.deep_sleep then p_tick - 1 else e.phys_tick end
              from (select e2.id, v.gx, v.gz, v.dur, v.yaw, v.dormant as dorm
                      from mc.entity e2 join mc.entity_type_param p on p.type = e2.type
                      cross join lateral mc.entity_goal_v(e2.id, p_tick, e2.yaw, coalesce(p.stroll_speed, p.walk_speed), e2.born_tick, (e2.gx <> 0 or e2.gz <> 0), e2.x, e2.y, e2.z, e2.cx, e2.cz, mc.entity_dormant_radius()) v
                     where p.kind = 'mob' and e2.goal_until > 0 and e2.goal_until <= p_tick) g
             where e.id = g.id returning e.id)
        select coalesce(array_agg(id), '{}') into a from u;
    else
        with u as (
            update mc.entity e set gx = g.gx, gz = g.gz, goal_until = p_tick + g.dur, yaw = g.yaw, deep_sleep = false,
                                   phys_tick = case when e.deep_sleep then p_tick - 1 else e.phys_tick end
              from (select q.id, case when q.r1 < wp then -sin(radians(q.r2 * 360)) * q.speed else 0 end as gx, case when q.r1 < wp then cos(radians(q.r2 * 360)) * q.speed else 0 end as gz,
                           case when q.r1 < wp then 20 + floor(q.r4 * 60)::int else 40 + floor(q.r4 * 100)::int end as dur,
                           case when q.r1 < wp then (q.r2 * 360)::real else q.yaw end as yaw
                      from (select e2.id, e2.yaw, p.walk_speed * (0.6 + 0.4 * h.r3) as speed, h.r1, h.r2, h.r4
                              from mc.entity e2 join mc.entity_type_param p on p.type = e2.type
                              cross join lateral (select abs(hashtextextended(e2.id::text || ':' || p_tick::text, 0)) as hv) hh
                              cross join lateral (select (hh.hv % 1000) / 1000.0 as r1, ((hh.hv / 1000) % 1000) / 1000.0 as r2, ((hh.hv / 1000000) % 1000) / 1000.0 as r3, ((hh.hv / 1000000000) % 1000) / 1000.0 as r4) h
                             where p.kind = 'mob' and e2.goal_until > 0 and e2.goal_until <= p_tick) q) g
             where e.id = g.id returning e.id)
        select coalesce(array_agg(id), '{}') into a from u;
    end if;
    if exists (select 1 from mc.entity z where z.type = 'minecraft:zombie') then
    with u as (
        update mc.entity e set gx = c.gx, gz = c.gz, goal_until = p_tick + 5, yaw = c.yaw, deep_sleep = false, phys_tick = case when e.deep_sleep then p_tick - 1 else e.phys_tick end
          from (select distinct on (z.id) z.id, (p.walk_speed * (pl.px - z.x) / sqrt((pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2)) as gx, (p.walk_speed * (pl.pz - z.z) / sqrt((pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2)) as gz,
                       degrees(atan2(-(pl.px - z.x), (pl.pz - z.z)))::real as yaw
                  from mc.entity z join mc.entity_type_param p on p.type = z.type and p.can_chase
                  cross join lateral generate_series(-1, 1) dx cross join lateral generate_series(-1, 1) dz
                  join (select pp.x as px, pp.z as pz, pp.chunk_x as pcx, pp.chunk_z as pcz from mc.player pp where pp.conn_id is not null) pl on pl.pcx = z.cx + dx and pl.pcz = z.cz + dz
                 where z.type = 'minecraft:zombie' and (z.id + p_tick) % 5 = 0
                   and (pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2 between 0.25 and 256
                 order by z.id, (pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2) c
         where e.id = c.id returning e.id)
    select coalesce(array_agg(id), '{}') into b from u;
    end if;
    return a || b;
end $$;

-- Exact current positions (lane rows are written at the tracker cadence): what a reader of mc.entity wants.
create or replace view mc.entity_live as
select e.id, e.type, e.dimension,
       case when e.lane_until > 0 then e.x + e.gx * greatest(t.t - e.phys_tick, 0) else e.x end as x, e.y,
       case when e.lane_until > 0 then e.z + e.gz * greatest(t.t - e.phys_tick, 0) else e.z end as z,
       e.on_ground, e.lane_until > 0 as in_lane
  from mc.entity e cross join (select coalesce(nullif(current_setting('dbcraft.entity_tick', true), '')::bigint, 0) as t) t;

-- The entity tick with lanes (sql/530's, plus the lane steps).  dbcraft.entity_lanes = 'off' gives the exact sweep for everybody, for comparison and fallback.
create or replace function mc.entity_tick(p_tick bigint default null) returns int language plpgsql volatile as $$
declare t bigint := coalesce(p_tick, (select game_time from mc.game_state limit 1), 0); ids int[]; lids int[] := '{}'; fl int[] := '{}'; ai int[];
        t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; nsent int; npick int; lanes boolean := mc.entity_lanes_enabled();
begin
    if coalesce(current_setting('dbcraft.entity_impl', true), '') = 'proto' then return mc.entity_tick_proto(t); end if;       -- the original prototype (tests/bench/entity/proto_baseline.sql), for comparison only
    perform set_config('dbcraft.entity_tick', t::text, false);
    perform mc.entity_viewers_refresh(t);
    if lanes then fl := mc.entity_lane_flush(t); else perform mc.entity_lane_flush_all(t); end if;
    ai := mc.entity_ai_ids(t);
    if coalesce(current_setting('dbcraft.entity_spawner', true), 'on') <> 'off' then perform mc.entity_spawner(t); end if;
    perform mc.entity_despawn(t);
    if lanes then
        perform mc.entity_lane_try(t, fl || ai);                  -- goal just given: walk on in a lane if the footprint is clean (no sweep this tick)
        lids := mc.entity_lane_step(t);                         -- lean tracker for lane mobs: plain packets built here, a position sync (rare) comes back for the generic tracker
    end if;
    t1 := clock_timestamp();
    ids := mc.entity_physics_ids(t);
    t2 := clock_timestamp();
    nsent := mc.entity_tracker(t, ids || lids);
    -- landed, just placed, or back from a position sync: may (re)start a lane.  AFTER the tracker: a lane copies what the viewers were last told, and this tick's packet is part of it
    -- (started before it, the lane's delta base would be one packet behind the viewers: found by tests/sql/541 E, a constant offset of that packet's delta).
    if lanes then perform mc.entity_lane_try(t, ids || lids); end if;
    t3 := clock_timestamp();
    npick := mc.entity_pickup(t);
    t4 := clock_timestamp();
    insert into mc.entity_tick_log (tick, awake, moved, sent, packets, ms_physics, ms_ai, ms_tracker, ms_pickup, ms_total)
    values (t, cardinality(ids) + cardinality(lids) + (select count(*)::int from mc.entity_lane), nsent, nsent, 0, extract(epoch from t2 - t1) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t3 - t2) * 1000, extract(epoch from t4 - t3) * 1000, extract(epoch from t4 - t0) * 1000)
    on conflict (tick) do update set awake = excluded.awake, moved = excluded.moved, sent = excluded.sent, packets = excluded.packets, ms_physics = excluded.ms_physics, ms_ai = excluded.ms_ai,
                                     ms_tracker = excluded.ms_tracker, ms_pickup = excluded.ms_pickup, ms_total = excluded.ms_total;
    return cardinality(ids) + cardinality(lids);
end $$;

-- The 'enters the view' announcement of sql/530's mc.entity_viewers_refresh, with one change: a lane entity appears at its delta base (see above).
create or replace function mc.entity_viewers_refresh(p_tick bigint) returns int language plpgsql volatile
set enable_hashjoin = off set enable_mergejoin = off as $$      -- the joins here are a few hundred array rows against tables of 200,000 rows: primary-key probes, never scans
declare vr int := mc.prop_int('view-distance'); cc int[]; ncx int[]; ncz int[]; ocx int[]; ocz int[]; n int := 0;
        rm_conn int[]; rm_cx int[]; rm_cz int[]; rm_ox int[]; rm_oz int[];      -- cells that left a view (and the old centre of that view)
        ad_conn int[]; ad_cx int[]; ad_cz int[]; ad_nx int[]; ad_nz int[];      -- cells that entered a view (and the new centre)
        dirty int[]; ovr int;
begin
    -- dirty-driven (sql/500: mc.entity_view_dirty): only the players that joined, left, changed chunk, or whose view distance changed are looked at; nobody dirty: nothing to do
    select c.vr into ovr from mc.entity_clock c;
    if ovr is distinct from vr then
        insert into mc.entity_view_dirty select pl.conn_id from mc.player pl where pl.conn_id is not null on conflict do nothing;
        insert into mc.entity_clock (id, last_tick, vr) values (true, null, vr) on conflict (id) do update set vr = excluded.vr;
    end if;
    if not exists (select 1 from mc.entity_view_dirty) then return 0; end if;
    with d as (delete from mc.entity_view_dirty returning conn_id) select array_agg(conn_id) into dirty from d;
    with gone as (delete from mc.entity_viewer_cell vc where vc.conn_id = any(dirty) and vc.conn_id not in (select pl.conn_id from mc.player pl where pl.conn_id is not null) returning conn_id)      -- NOT IN (hashed): the function-level enable_hashjoin = off turned the NOT EXISTS anti-join into 500 x 500 comparisons (8 ms per tick at 500 players)
    delete from mc.entity_cell_viewer v using gone g where v.conn_id = g.conn_id;
    select array_agg(pl.conn_id), array_agg(pl.chunk_x), array_agg(pl.chunk_z), array_agg(vc.cx), array_agg(vc.cz) into cc, ncx, ncz, ocx, ocz
      from mc.player pl left join mc.entity_viewer_cell vc on vc.conn_id = pl.conn_id
     where pl.conn_id = any(dirty) and (vc.conn_id is null or vc.cx <> pl.chunk_x or vc.cz <> pl.chunk_z or vc.r <> vr);
    if cc is null then return 0; end if;
    n := cardinality(cc);
    -- the rings first (a few dozen cells per crossing player), as arrays: the planner then knows how small the driving side is
    select array_agg(q.conn), array_agg(q.cx), array_agg(q.cz), array_agg(q.ox), array_agg(q.oz) into rm_conn, rm_cx, rm_cz, rm_ox, rm_oz
      from (select ch.conn, ch.ocx + dx as cx, ch.ocz + dz as cz, ch.ocx as ox, ch.ocz as oz
              from unnest(cc, ncx, ncz, ocx, ocz) ch(conn, ncx, ncz, ocx, ocz), generate_series(-vr, vr) dx, generate_series(-vr, vr) dz
             where ch.ocx is not null and (abs(ch.ocx + dx - ch.ncx) > vr or abs(ch.ocz + dz - ch.ncz) > vr)) q;
    select array_agg(q.conn), array_agg(q.cx), array_agg(q.cz), array_agg(q.nx), array_agg(q.nz) into ad_conn, ad_cx, ad_cz, ad_nx, ad_nz
      from (select ch.conn, ch.ncx + dx as cx, ch.ncz + dz as cz, ch.ncx as nx, ch.ncz as nz
              from unnest(cc, ncx, ncz, ocx, ocz) ch(conn, ncx, ncz, ocx, ocz), generate_series(-vr, vr) dx, generate_series(-vr, vr) dz
             where ch.ocx is null or abs(ch.ncx + dx - ch.ocx) > vr or abs(ch.ncz + dz - ch.ocz) > vr) q;
    -- lazy lanes (sql/940) near the cells that enter a view are brought up to date first: the announcement below reads their entity rows and delta bases
    if ad_conn is not null then perform mc.entity_auto_catchup(p_tick - 1, mc.entity_auto_lanes_near(p_tick - 1, ncx, ncz, vr + 1)); end if;
    if rm_conn is not null then
        -- what leaves the view: the entities in the cells that left it, within their tracking range of the OLD centre, are removed
        insert into mc.play_out (conn_id, data)
        select q.conn, mc.pkt_remove_entities(array_agg(q.eid order by q.eid))
          from (select r.conn, e.id as eid
                  from unnest(rm_conn, rm_cx, rm_cz, rm_ox, rm_oz) r(conn, cx, cz, ox, oz)
                  join mc.entity e on e.cx = r.cx and e.cz = r.cz and e.last_sent_tick > 0
                  join mc.entity_type_param p on p.type = e.type
                 where greatest(abs(r.ox - e.cx), abs(r.oz - e.cz)) <= least(vr, p.tracking_chunks)) q
         group by q.conn order by q.conn;
        delete from mc.entity_cell_viewer v using unnest(rm_conn, rm_cx, rm_cz) r(conn, cx, cz) where v.cx = r.cx and v.cz = r.cz and v.conn_id = r.conn;
    end if;
    if ad_conn is not null then
        -- what enters the view: the entities in the new cells within their tracking range of the NEW centre appear
        insert into mc.play_out (conn_id, data)
        select q.conn, string_agg(q.pkt, '\x'::bytea order by q.eid)
          from (select a.conn, e.id as eid, mc.epkt_appear(e.id, e.uuid, e.type, e.type_id, case when ln.auto then ab.bx / 4096.0 when ln.id is not null then ln.sqx / 4096.0 else e.x end, e.y,
                                                           case when ln.auto then ab.bz / 4096.0 when ln.id is not null then ln.sqz / 4096.0 else e.z end,
                                                           case when ln.auto then ln.gx else e.vx end, e.vy, case when ln.auto then ln.gz else e.vz end, case when ln.auto then ln.yaw else e.yaw end, e.pitch, e.data) as pkt
                  from unnest(ad_conn, ad_cx, ad_cz, ad_nx, ad_nz) a(conn, cx, cz, nx, nz)
                  join mc.entity e on e.cx = a.cx and e.cz = a.cz and e.last_sent_tick > 0
                  left join mc.entity_lane ln on ln.id = e.id     -- a lane entity is not rewritten while it walks: it appears where its viewers last saw it (their delta base)
                  left join lateral (select b.bx, b.bz from mc.entity_auto_base(ln.t0, ln.every, ln.slot, ln.x0, ln.z0, ln.y, ln.gx, ln.gz, ln.yaw, ln.goal_until, ln.born, ln.sqx, ln.sqy, ln.sqz, ln.syaw, ln.last_tick, p_tick - 1) b
                                      where ln.auto) ab on true      -- an autonomous lane (sql/940): the base after the steps up to the last tick, from the closed form; its entity row is the anchor of the first segment only
                  join mc.entity_type_param p on p.type = e.type
                 where greatest(abs(a.nx - e.cx), abs(a.nz - e.cz)) <= least(vr, p.tracking_chunks)) q
         group by q.conn order by q.conn;
        insert into mc.entity_cell_viewer (cx, cz, conn_id) select a.cx, a.cz, a.conn from unnest(ad_conn, ad_cx, ad_cz) a(conn, cx, cz) on conflict do nothing;
    end if;
    insert into mc.entity_viewer_cell (conn_id, cx, cz, r)
    select ch.conn, ch.ncx, ch.ncz, vr from unnest(cc, ncx, ncz) ch(conn, ncx, ncz)
    on conflict (conn_id) do update set cx = excluded.cx, cz = excluded.cz, r = excluded.r;
    -- lanes that nobody could see (lazy, sql/940) and are now within reach of a viewer's new cell are simulated tick by tick from this tick on
    update mc.entity_lane l set lazy = false
     where l.auto and l.lazy and not l.dormant and exists (select 1 from unnest(ncx, ncz) c(x, z) where greatest(abs(l.cx - c.x), abs(l.cz - c.z)) <= least(l.trk, vr) + 1);
    -- vanilla-like AI (sql/942): a DORMANT mob (standing, nobody within 2 chunks) has no events; a player who arrives within reach is vanilla's "noActionTime reset": the mob draws a wait from this tick
    -- (lane rows and rows of mobs outside lanes alike)
    if mc.entity_ai_vanilla() then
        update mc.entity_lane l set dormant = false, lazy = false, goal_until = w.td, gend = w.td
          from (select distinct l0.id, mc.entity_stroll_wait(l0.id, p_tick, l0.born) as td
                  from unnest(ncx, ncz) c(x, z) cross join lateral (select l1.id, l1.born from mc.entity_lane l1
                       where l1.dormant and l1.cx between c.x - mc.entity_dormant_radius() and c.x + mc.entity_dormant_radius() and l1.cz between c.z - mc.entity_dormant_radius() and c.z + mc.entity_dormant_radius() offset 0) l0) w
         where l.id = w.id;
        update mc.entity e set goal_until = mc.entity_stroll_wait(e.id, p_tick, e.born_tick)
          from (select distinct c.x, c.z from unnest(ncx, ncz) c(x, z)) c
         where e.goal_until = 4611686018427387904 and e.cx between c.x - mc.entity_dormant_radius() and c.x + mc.entity_dormant_radius() and e.cz between c.z - mc.entity_dormant_radius() and c.z + mc.entity_dormant_radius();
    end if;
    return n;
end $$;

