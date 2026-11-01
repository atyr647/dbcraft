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
      'minecraft:red_mushroom', 'minecraft:nether_sprouts', 'minecraft:crimson_roots', 'minecraft:warped_roots', 'minecraft:hanging_roots',
      -- verified against a captured vanilla pale-garden chunk set (vanilla excludes these from MOTION_BLOCKING):
      'minecraft:pale_hanging_moss', 'minecraft:pale_moss_carpet', 'minecraft:leaf_litter',
      -- NOT verified (same family, judged likely): moss_carpet, glow_lichen, sculk_vein, dry grass, bush, firefly_bush, wildflowers, petals, cactus_flower
      'minecraft:moss_carpet', 'minecraft:glow_lichen', 'minecraft:sculk_vein', 'minecraft:short_dry_grass', 'minecraft:tall_dry_grass', 'minecraft:bush',
      'minecraft:firefly_bush', 'minecraft:wildflowers', 'minecraft:pink_petals', 'minecraft:cactus_flower')
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

    -- MATERIALIZED: otherwise the planner inlines the flag arrays into the per-block expression and recomputes them 4096 times per section
    with secs as materialized (
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
-- Byte k of the layer holds the columns x = 2 * (k & 7) (low nibble) and x + 1 (high nibble) of row z = (k >> 3) & 15 at height y = k >> 7.
--
-- The first version aggregated 2,048 formatted bytes (0.64 ms per partial layer).  A column is lit from row r = clamp(surface - base, 0, 16) upwards, so the rows
-- are cumulative: row y lights exactly the columns whose r <= y.  The lit columns are kept as four 64-bit masks per row; a mask bit, read as text, is turned
-- into a hex digit by translate(), and the columns are numbered (col # 1) so that the text order of the bits is the byte order of the layer (the high nibble,
-- the odd column, comes first).  Uniform surfaces (flat worlds) need no per-column work at all.
-- plpgsql so that the plan is cached (a LANGUAGE sql function with a FROM clause is planned again on every call).
create or replace function mc.sky_layer(hm smallint[], base int) returns bytea language plpgsql immutable parallel safe set plan_cache_mode = force_generic_plan as $$
declare
    lo int; hi int; t int; r bytea;
begin
    select min(h), max(h) into lo, hi from unnest(hm) h;
    if lo = hi then
        t := least(greatest(lo - base, 0), 16);                          -- rows below t are dark, the rest lit
        return decode(repeat('00', 128 * t) || repeat('ff', 128 * (16 - t)), 'hex');
    end if;
    with cols as (
        select (c # 1) as n, greatest(least(hm[c + 1] - base, 16), 0) as thr from generate_series(0, 255) c),
    g as (
        select thr, n >> 6 as j, bit_or(1::bigint << (63 - (n & 63))) as m from cols group by 1, 2),
    grid as (
        select y, jj as j, coalesce(g.m, 0) as m from generate_series(0, 15) y cross join generate_series(0, 3) jj left join g on g.thr = y and g.j = jj),
    acc as (
        select y, j, bit_or(m) over (partition by j order by y) as a from grid),
    rows as (
        select y, translate((max(a) filter (where j = 0))::bit(64)::text || (max(a) filter (where j = 1))::bit(64)::text
                            || (max(a) filter (where j = 2))::bit(64)::text || (max(a) filter (where j = 3))::bit(64)::text, '01', '0f') as hx
          from acc group by y)
    select decode(string_agg(hx, '' order by y), 'hex') into r from rows;
    return r;
end $$;

-- Rebuilds the light rows of a chunk.  Layers 0 .. (index of the highest non-empty section + 2); layer 0 lies below the world.
-- p_sky0_as_data: vanilla sometimes sends layer 0 as a present all-zero array instead of an "empty" bit (a transient of its light engine, seen on the first
-- chunks of a session); pass true to reproduce that form.
--
-- Light is a pure function of the WORLD_SURFACE heightmap and of the highest non-empty section, and mc.chunk.light_ws / light_top remember the inputs the stored
-- rows were computed from: an edit that changed neither (a block placed or removed below the surface) costs one comparison instead of a rebuild.
-- When the inputs did change, all partial layers are built in ONE statement (the columns are grouped by surface height once, then every absolute level gets its
-- cumulative mask; a layer is 16 consecutive levels), and only layers whose content differs from the stored row are written.
create or replace function mc.compute_light(p_dim text, p_cx int, p_cz int, p_sky0_as_data boolean default false) returns void language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    v_min_y    int;
    v_height   int;
    hm         smallint[];
    k_ws       smallint[];
    k_top      smallint;
    top        int;
    min_sy     int;
    nsec       int;
    last_layer int;
    lo         int;
    hi         int;
    b0         int;
    b1         int;
    ff         bytea := decode(repeat('ff', 2048), 'hex');
begin
    select d.min_y, d.height, c.hm_world_surface, c.light_ws, c.light_top into v_min_y, v_height, hm, k_ws, k_top
      from mc.dimension d left join mc.chunk c on c.dimension = d.name and c.cx = p_cx and c.cz = p_cz
     where d.name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if hm is null then raise exception 'chunk %,% of % has no heightmaps; compute them first', p_cx, p_cz, p_dim; end if;
    min_sy := v_min_y >> 4;
    nsec := v_height / 16;
    select max(s.sy) - min_sy into top from mc.chunk_section s
     where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.block_count > 0;
    top := coalesce(top, -1);
    last_layer := least(top + 2, nsec + 1);
    if not p_sky0_as_data and k_ws is not distinct from hm and k_top is not distinct from top::smallint
       and (select count(*) from mc.chunk_light l where l.dimension = p_dim and l.cx = p_cx and l.cz = p_cz) = last_layer + 1 then
        return;                                                    -- the stored rows already are this function's output
    end if;
    select min(x), max(x) into lo, hi from unnest(hm) x;
    -- levels (heights relative to the world bottom) covered by partial layers: layer lay spans [16 * (lay - 1), 16 * lay); uniform surfaces need no level table
    b0 := (lo / 16) * 16;
    b1 := case when lo = hi then b0 else ((hi + 15) / 16) * 16 end;

    delete from mc.chunk_light l where l.dimension = p_dim and l.cx = p_cx and l.cz = p_cz and l.idx > last_layer;
    with g as (
        select hm[c + 1]::int as h, (c # 1) >> 6 as j, bit_or(1::bigint << (63 - ((c # 1) & 63))) as m
          from generate_series(0, 255) c group by 1, 2),
    lv as (
        select a, jj as j, coalesce(g.m, 0) as m from generate_series(b0, b1 - 1) a cross join generate_series(0, 3) jj left join g on g.h = a and g.j = jj),
    acc as (
        select a, j, bit_or(m) over (partition by j order by a) as cm from lv),
    txt as (
        select a, translate((max(cm) filter (where j = 0))::bit(64)::text || (max(cm) filter (where j = 1))::bit(64)::text
                            || (max(cm) filter (where j = 2))::bit(64)::text || (max(cm) filter (where j = 3))::bit(64)::text, '01', '0f') as hx
          from acc group by a),
    pl as (
        select (a - b0) / 16 as off, decode(string_agg(hx, '' order by a), 'hex') as arr from txt group by 1),
    want as (
        select lay,
               case when lay = 0 then (case when p_sky0_as_data then 'data' else 'empty' end)
                    when b.base >= hi then 'data' when b.base + 16 <= lo then 'empty' else 'data' end as sky_kind,
               case when lay = 0 then (case when p_sky0_as_data then decode(repeat('00', 2048), 'hex') end)
                    when b.base >= hi then ff when b.base + 16 <= lo then null
                    else coalesce((select pl.arr from pl where pl.off = (b.base - b0) / 16), mc.sky_layer(hm, b.base)) end as sky
          from generate_series(0, last_layer) lay, lateral (select (min_sy + lay - 1) * 16 - v_min_y as base) b)
    insert into mc.chunk_light as l (dimension, cx, cz, idx, sky_kind, sky, block_kind, block)
    select p_dim, p_cx, p_cz, w.lay, w.sky_kind, w.sky, 'empty', null from want w
    on conflict (dimension, cx, cz, idx) do update set sky_kind = excluded.sky_kind, sky = excluded.sky, block_kind = excluded.block_kind, block = excluded.block
     where (l.sky_kind, l.sky, l.block_kind, l.block) is distinct from (excluded.sky_kind, excluded.sky, excluded.block_kind, excluded.block);
    -- vanilla's layer-0 variant is not what a later call without the flag would produce, so it must not leave a key behind
    update mc.chunk c set light_ws = case when p_sky0_as_data then null else hm end, light_top = case when p_sky0_as_data then null else top::smallint end
     where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
end $$;

-- Height value of the highest block at or below p_from_y in one column that satisfies heightmap kind p_kind (1 = WORLD_SURFACE, 2 = MOTION_BLOCKING,
-- 3 = MOTION_BLOCKING_NO_LEAVES): (y + 1) - min_y, or 0 when there is none.  Used to re-find a column's top after its top block was removed.
create or replace function mc.column_top(p_dim text, p_cx int, p_cz int, p_col int, p_from_y int, p_kind int) returns int language plpgsql stable as $$
declare
    p_min_y int;
    s       int;
    top_ly  int;
    ly      int;
    sec     record;
    ent     int;
    nm      text;
    lx      int := p_col & 15;
    lz      int := p_col >> 4;
begin
    select d.min_y into p_min_y from mc.dimension d where d.name = p_dim;
    for s in reverse (p_from_y >> 4) .. (p_min_y >> 4) loop
        select cs.block_count, cs.bits, cs.palette, cs.data into sec from mc.chunk_section cs
         where cs.dimension = p_dim and cs.cx = p_cx and cs.cz = p_cz and cs.sy = s;
        if not found or sec.block_count = 0 then continue; end if;
        top_ly := case when s = p_from_y >> 4 then p_from_y & 15 else 15 end;
        for ly in reverse top_ly .. 0 loop
            ent := mc.entry_at(sec.bits, sec.data, (ly << 8) | (lz << 4) | lx);
            nm := case when cardinality(sec.palette) = 0 then mc.state_name(ent) else sec.palette[ent + 1] end;
            if (mc.heightmap_flags(nm))[p_kind] then return s * 16 + ly + 1 - p_min_y; end if;
        end loop;
    end loop;
    return 0;
end $$;

-- One edit's effect on one column's height: a qualifying block above the top raises it; removing the top block (and nothing qualifying replacing it)
-- re-finds the top below.  Called after the edited section has been written, so a rescan sees the final data.
create or replace function mc.hm_step(h smallint, val int, oldf boolean, newf boolean, p_dim text, p_cx int, p_cz int, p_col int, p_kind int, p_min_y int)
returns smallint language plpgsql stable as $$
begin
    if newf and val > h then return val::smallint; end if;
    if oldf and not newf and val = h then return mc.column_top(p_dim, p_cx, p_cz, p_col, val - 2 + p_min_y, p_kind)::smallint; end if;
    return h;
end $$;

-- Bring a chunk's derived data up to date: heightmaps in full when they are missing or flagged (hm_dirty), light when anything changed.
-- Returns false when there was nothing to do.
create or replace function mc.ensure_chunk_current(p_dim text, p_cx int, p_cz int) returns boolean language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    c mc.chunk%rowtype;
    h record;
begin
    -- The lock is only needed to serialize two callers that both find the chunk dirty, so a chunk that is current is judged without it: taking a row lock on every
    -- call wrote the locked tuple to the WAL each time (the tuning measurements found 16% of the WAL of a 500-player tick in these locks, before mc.chunk_packet stopped
    -- calling this function for current chunks; the other callers, such as mc.generate_flat, still do).  A dirty chunk is read again under the lock.
    select * into c from mc.chunk k where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz;
    if not found then return false; end if;
    if not c.dirty and not c.hm_dirty and c.hm_world_surface is not null then return false; end if;
    select * into c from mc.chunk k where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz for update;
    if not found then return false; end if;
    if not c.dirty and not c.hm_dirty and c.hm_world_surface is not null then return false; end if;      -- another session brought it up to date while this one waited for the lock
    if c.hm_dirty or c.hm_world_surface is null then
        select * into h from mc.compute_heightmaps(p_dim, p_cx, p_cz);
        update mc.chunk k set hm_motion_blocking = h.motion_blocking, hm_motion_blocking_no_leaves = h.motion_blocking_no_leaves,
                              hm_world_surface = h.world_surface, hm_dirty = false
         where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz;
    end if;
    perform mc.compute_light(p_dim, p_cx, p_cz);
    update mc.chunk k set dirty = false where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz;
    return true;
end $$;
