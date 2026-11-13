-- Light engine, part 6: the entry points.  See docs/LIGHT.md.
--
-- mc.light_flat_ok(dim, cx, cz)   true when the chunk and its existing neighbours are "uniform": the WORLD_SURFACE heightmap is the same constant h in all of them, every
--                                 section below h is completely filled, none above has a block, and every state in the palettes is either air (dampening 0, no emission) or
--                                 opaque (dampening 15, no emission, no occlusion shape).  Then the engine's result is exactly 15 above h and 0 below, which is what
--                                 mc.compute_light_flat writes (about a tenth of the engine's cost; every flat world is like this).
-- mc.light_chunks(dim, cxs, czs)  light of freshly created chunks, in one call: the uniform ones with the flat model, the rest in one region.  Existing neighbours that
--                                 were lit while these chunks were missing are lit again (their light depends on them); chunks whose rows changed and that already
--                                 have been served get a new version (so their cached packet is rebuilt).  Returns the number of chunks lit.
create or replace function mc.light_flat_ok(p_dim text, p_cx int, p_cz int) returns boolean language plpgsql stable set plan_cache_mode = force_generic_plan set jit = off as $$
declare
    v_min_sy int;
    h        int;
    n        int;
    bad      boolean;
begin
    select d.min_y >> 4 into v_min_sy from mc.dimension d where d.name = p_dim;
    select (c.hm_world_surface)[1] into h from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz and c.hm_world_surface is not null;
    if h is null then return false; end if;
    select count(*), bool_or(c.hm_world_surface is null or c.hm_world_surface <> array_fill(h::smallint, array[256])) into n, bad
      from mc.chunk c where c.dimension = p_dim and c.cx between p_cx - 1 and p_cx + 1 and c.cz between p_cz - 1 and p_cz + 1;
    if bad then return false; end if;
    return not exists (
        select 1 from mc.chunk_section s
         where s.dimension = p_dim and s.cx between p_cx - 1 and p_cx + 1 and s.cz between p_cz - 1 and p_cz + 1 and s.block_count > 0
           and (s.block_count <> 256 * greatest(0, least(16, h - (s.sy - v_min_sy) * 16))
                or cardinality(s.palette) = 0
                or exists (select 1 from unnest(s.palette) u(nm) left join mc.light_state l on l.name = u.nm
                            where l.sid is null or l.emission > 0 or l.shaped or l.damp not in (0, 15))));
end $$;

create or replace function mc.light_chunks(p_dim text, p_cxs int[], p_czs int[]) returns int language plpgsql volatile set plan_cache_mode = force_generic_plan set jit = off as $$
declare
    xs int[]; zs int[];                     -- the chunks of the region call
    fx int[]; fz int[];                     -- the uniform ones
    k int;
    n int := 0;
begin
    if p_cxs is null or cardinality(p_cxs) = 0 then return 0; end if;
    if not mc.light_ready() then
        for k in 1 .. cardinality(p_cxs) loop perform mc.compute_light_flat(p_dim, p_cxs[k], p_czs[k]); end loop;
        return cardinality(p_cxs);
    end if;
    -- the new chunks and the existing neighbours that were lit without them (the uniform ones do not care)
    with t as (select distinct u.cx, u.cz from unnest(p_cxs, p_czs) u(cx, cz)),
    nb as (select distinct t.cx + dx as cx, t.cz + dz as cz from t, generate_series(-1, 1) dx, generate_series(-1, 1) dz),
    want as (
        select nb.cx, nb.cz, exists (select 1 from t where t.cx = nb.cx and t.cz = nb.cz) as is_new
          from nb join mc.chunk c on c.dimension = p_dim and c.cx = nb.cx and c.cz = nb.cz),
    cls as (select w.cx, w.cz, w.is_new, mc.light_flat_ok(p_dim, w.cx, w.cz) as flat from want w)
    select array_agg(cx) filter (where not flat), array_agg(cz) filter (where not flat), array_agg(cx) filter (where flat and is_new), array_agg(cz) filter (where flat and is_new)
      into xs, zs, fx, fz from cls;
    for k in 1 .. coalesce(cardinality(fx), 0) loop
        perform mc.compute_light_flat(p_dim, fx[k], fz[k]);
        n := n + 1;
    end loop;
    if coalesce(cardinality(xs), 0) > 0 then
        perform mc.light_region(p_dim, xs, zs);
        n := n + cardinality(xs);
        -- an existing chunk (not one of the new ones) whose light changed: new packet
        update mc.chunk c set version = c.version + 1
          from lw_chg g
         where c.dimension = p_dim and c.cx = g.cx and c.cz = g.cz and not exists (select 1 from unnest(p_cxs, p_czs) u(cx, cz) where u.cx = g.cx and u.cz = g.cz);
    end if;
    return n;
end $$;

-- The stored light of one cell: kind 'sky' or 'block'; 0 where the layer holds none.  (What the clients see; vanilla's Level.getBrightness / getRawBrightness read the same arrays.)
create or replace function mc.light_at(p_dim text, p_x int, p_y int, p_z int, p_kind text default 'block') returns int language plpgsql stable as $$
declare
    v_min_sy int;
    k text; a bytea; i int; b int;
begin
    select d.min_y >> 4 into v_min_sy from mc.dimension d where d.name = p_dim;
    select case when p_kind = 'sky' then l.sky_kind else l.block_kind end, case when p_kind = 'sky' then l.sky else l.block end into k, a
      from mc.chunk_light l where l.dimension = p_dim and l.cx = p_x >> 4 and l.cz = p_z >> 4 and l.idx = (p_y >> 4) - v_min_sy + 1;
    if not found or k <> 'data' or a is null then return 0; end if;
    i := ((p_y & 15) << 8) | ((p_z & 15) << 4) | (p_x & 15);
    b := get_byte(a, i >> 1);
    return case when (i & 1) = 1 then b >> 4 else b & 15 end;
end $$;
