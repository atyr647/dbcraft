-- Derived chunk data: heightmaps and light, recomputed from the stored sections.
--
-- What is and is not modelled (see docs/WORLD.md):
--   heightmaps  WORLD_SURFACE is exact (highest non-air block).  MOTION_BLOCKING / MOTION_BLOCKING_NO_LEAVES use a name-based approximation of
--               "blocks motion" (mc.non_collidable): the generator reports carry no collision data.
--   sky light   straight-down only: 15 above the highest non-air block of a column, 0 at and below it.  No horizontal spreading, no attenuation
--               by water or leaves, no cross-chunk effects.  Exact for flat worlds and any terrain without overhangs.
--   block light none: every layer is all zero (no emitter propagation).

------------------------------------------------------------------------------------------------ predicates
-- Blocks without a collision box (approximation: the common ones; extend as needed).
create or replace function mc.non_collidable(state text) returns boolean language sql immutable parallel safe as $$
  select split_part(state, '[', 1) in (
      'minecraft:short_grass', 'minecraft:tall_grass', 'minecraft:fern', 'minecraft:large_fern', 'minecraft:dead_bush', 'minecraft:vine',
      'minecraft:torch', 'minecraft:wall_torch', 'minecraft:soul_torch', 'minecraft:soul_wall_torch', 'minecraft:redstone_torch', 'minecraft:redstone_wall_torch',
      'minecraft:redstone_wire', 'minecraft:rail', 'minecraft:powered_rail', 'minecraft:detector_rail', 'minecraft:activator_rail',
      'minecraft:lever', 'minecraft:tripwire', 'minecraft:tripwire_hook', 'minecraft:cobweb', 'minecraft:fire', 'minecraft:soul_fire', 'minecraft:ladder',
      'minecraft:sugar_cane', 'minecraft:dandelion', 'minecraft:poppy', 'minecraft:blue_orchid', 'minecraft:allium', 'minecraft:azure_bluet',
      'minecraft:red_tulip', 'minecraft:orange_tulip', 'minecraft:white_tulip', 'minecraft:pink_tulip', 'minecraft:oxeye_daisy', 'minecraft:cornflower',
      'minecraft:lily_of_the_valley', 'minecraft:sunflower', 'minecraft:lilac', 'minecraft:rose_bush', 'minecraft:peony', 'minecraft:brown_mushroom',
      'minecraft:red_mushroom', 'minecraft:nether_sprouts', 'minecraft:crimson_roots', 'minecraft:warped_roots', 'minecraft:hanging_roots')
     or split_part(state, '[', 1) like '%\_sapling' or split_part(state, '[', 1) like '%\_button' or split_part(state, '[', 1) like '%\_pressure\_plate'
     or split_part(state, '[', 1) like '%\_sign' or split_part(state, '[', 1) like '%\_wall\_sign' or split_part(state, '[', 1) like '%\_hanging\_sign' $$;

create or replace function mc.is_leaves(state text) returns boolean language sql immutable parallel safe as $$
  select split_part(state, '[', 1) like '%\_leaves' $$;

-- Per-palette-entry heightmap flags: {world_surface, motion_blocking, motion_blocking_no_leaves}.
create or replace function mc.heightmap_flags(state text) returns boolean[] language sql immutable parallel safe as $$
  select array[not mc.is_air(state),
               not mc.is_air(state) and (mc.has_fluid(state) or not mc.non_collidable(state)),
               not mc.is_air(state) and (mc.has_fluid(state) or not mc.non_collidable(state)) and not mc.is_leaves(state)] $$;

------------------------------------------------------------------------------------------------ heightmaps
-- One value per column (index x + 16 * z): (highest qualifying y + 1) - min_y, or 0.  Set-based over every non-empty section of the chunk.
create or replace function mc.compute_heightmaps(p_dim text, p_cx int, p_cz int,
                                                 out motion_blocking smallint[], out motion_blocking_no_leaves smallint[], out world_surface smallint[])
language plpgsql stable as $$
declare
    p_min_y int;
begin
    select d.min_y into p_min_y from mc.dimension d where d.name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;

    with secs as (
        select s.sy, s.bits, s.data,
               case when cardinality(s.palette) > 0 then array(select (mc.heightmap_flags(n))[1] from unnest(s.palette) with ordinality p(n, o) order by o) end as wsf,
               case when cardinality(s.palette) > 0 then array(select (mc.heightmap_flags(n))[2] from unnest(s.palette) with ordinality p(n, o) order by o) end as mbf,
               case when cardinality(s.palette) > 0 then array(select (mc.heightmap_flags(n))[3] from unnest(s.palette) with ordinality p(n, o) order by o) end as nlf
        from mc.chunk_section s
        where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.block_count > 0),
    flagged as (
        -- palette sections index their flag arrays; a global-palette section (rare) looks the state up by id
        select s.sy, u.i - 1 as i,
               coalesce(s.wsf[u.e + 1], (mc.heightmap_flags(mc.state_name(u.e)))[1]) as f1,
               coalesce(s.mbf[u.e + 1], (mc.heightmap_flags(mc.state_name(u.e)))[2]) as f2,
               coalesce(s.nlf[u.e + 1], (mc.heightmap_flags(mc.state_name(u.e)))[3]) as f3
        from secs s, lateral unnest(mc.unpack_longs(s.data, s.bits, 4096)) with ordinality u(e, i)),
    cols as (
        select (f.i & 15) + 16 * ((f.i >> 4) & 15) as col,
               max(f.sy * 16 + (f.i >> 8)) filter (where f.f1) as ws,
               max(f.sy * 16 + (f.i >> 8)) filter (where f.f2) as mb,
               max(f.sy * 16 + (f.i >> 8)) filter (where f.f3) as nl
        from flagged f group by 1)
    select array(select coalesce(c.mb + 1 - p_min_y, 0)::smallint from generate_series(0, 255) g left join cols c on c.col = g order by g),
           array(select coalesce(c.nl + 1 - p_min_y, 0)::smallint from generate_series(0, 255) g left join cols c on c.col = g order by g),
           array(select coalesce(c.ws + 1 - p_min_y, 0)::smallint from generate_series(0, 255) g left join cols c on c.col = g order by g)
      into motion_blocking, motion_blocking_no_leaves, world_surface;
end $$;

------------------------------------------------------------------------------------------------ light
-- One sky-light layer: 2048 bytes of nibbles, 15 where the layer's y (relative to the world bottom) is at or above the column's surface value.
create or replace function mc.sky_layer(hm smallint[], base int) returns bytea language sql immutable parallel safe as $$
  select decode(string_agg(lpad(to_hex(
           (case when base + (k >> 7) >= hm[2 * (k & 7) + 16 * ((k >> 3) & 15) + 1] then 15 else 0 end)
         | (case when base + (k >> 7) >= hm[2 * (k & 7) + 16 * ((k >> 3) & 15) + 2] then 240 else 0 end)), 2, '0'), '' order by k), 'hex')
  from generate_series(0, 2047) k $$;

-- Rebuilds the light rows of a chunk.  Layers 0 .. (index of the highest non-empty section + 2); layer 0 lies below the world.
-- p_sky0_as_data: vanilla sometimes sends layer 0 as a present all-zero array instead of an "empty" bit (a transient of its light engine, seen on the first
-- chunks of a session); pass true to reproduce that form.
create or replace function mc.compute_light(p_dim text, p_cx int, p_cz int, p_sky0_as_data boolean default false) returns void language plpgsql volatile as $$
declare
    d          mc.dimension%rowtype;
    hm         smallint[];
    top        int;
    min_sy     int;
    nsec       int;
    last_layer int;
    lay        int;
    base       int;
    lo         int;
    hi         int;
    arr        bytea;
begin
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    select c.hm_world_surface into hm from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    if hm is null then raise exception 'chunk %,% of % has no heightmaps; compute them first', p_cx, p_cz, p_dim; end if;
    min_sy := d.min_y >> 4;
    nsec := d.height / 16;
    select max(s.sy) - min_sy into top from mc.chunk_section s
     where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.block_count > 0;
    top := coalesce(top, -1);
    last_layer := least(top + 2, nsec + 1);
    select min(x), max(x) into lo, hi from unnest(hm) x;

    delete from mc.chunk_light where dimension = p_dim and cx = p_cx and cz = p_cz;
    for lay in 0 .. last_layer loop
        if lay = 0 then
            insert into mc.chunk_light values (p_dim, p_cx, p_cz, 0,
                case when p_sky0_as_data then 'data' else 'empty' end, case when p_sky0_as_data then decode(repeat('00', 2048), 'hex') end,
                'empty', null);
            continue;
        end if;
        base := (min_sy + lay - 1) * 16 - d.min_y;            -- y of the layer's lowest block, relative to the world bottom
        if base >= hi then
            arr := decode(repeat('ff', 2048), 'hex');
            insert into mc.chunk_light values (p_dim, p_cx, p_cz, lay, 'data', arr, 'empty', null);
        elsif base + 16 <= lo then
            insert into mc.chunk_light values (p_dim, p_cx, p_cz, lay, 'empty', null, 'empty', null);
        else
            insert into mc.chunk_light values (p_dim, p_cx, p_cz, lay, 'data', mc.sky_layer(hm, base), 'empty', null);
        end if;
    end loop;
end $$;

-- Recompute heightmaps and light if the chunk was edited since they were last computed.
create or replace function mc.ensure_chunk_current(p_dim text, p_cx int, p_cz int) returns boolean language plpgsql volatile as $$
declare h record;
begin
    perform 1 from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz and c.dirty for update;
    if not found then return false; end if;
    select * into h from mc.compute_heightmaps(p_dim, p_cx, p_cz);
    update mc.chunk c set hm_motion_blocking = h.motion_blocking, hm_motion_blocking_no_leaves = h.motion_blocking_no_leaves,
                          hm_world_surface = h.world_surface, dirty = false
     where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    perform mc.compute_light(p_dim, p_cx, p_cz);
    return true;
end $$;
