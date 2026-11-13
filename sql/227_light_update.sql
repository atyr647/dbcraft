-- Light engine, part 7: light after edits.  See docs/LIGHT.md.
--
-- An edit changes light only where light travels from it: at most 14 cells.  mc.light_update(dim, xs, ys, zs) recomputes the light of the sections that intersect the
-- cube of +-14 cells around the changed cells (the "free" sections) with the same waves as mc.light_region, from the blocks, and takes everything outside as given:
--   * the cells of the sections next to the free ones (the "frozen" sections, their stored light) start waves at their stored level, so the light that flows in from outside
--     is what is stored there, and nothing can land in them;
--   * the sky sources of a free section are cut off where the section above (stored) ends them: the column's "an opaque cell above" mask is read from the cells of the
--     stored section above whose stored sky level is not 15.
-- Sections of the other chunks are not touched, so chunks next to the edited one are brought up to date in the same call.  The result equals mc.light_region (the tests
-- compare both after random edits).  Cases the cube cannot express answer -1 and the caller relights the chunks as a whole: more than 120 sections in the cube, or a
-- change of which sections are non-empty (a first block in an empty section, the last block of a section removed: the set of light layers of three chunks changes).
-- The rows that changed are listed in lw_delta (chunk, layer index, sky changed, block changed) for the light_update packets.

-- masks of the cells of a stored light array that have exactly level l, for every level present (the frozen sections' waves)
create or replace function mc.light_levels(p_arr bytea) returns table (lvl int, m bit(4096)) language plpgsql immutable parallel safe as $$
declare
    p record;
    l int;
    x bit(4096);
begin
    if p_arr is null then return; end if;
    if p_arr = decode(repeat('ff', 2048), 'hex') then lvl := 15; m := mc.lk_ones(); return next; return; end if;
    select * into p from mc.light_planes(p_arr);
    for l in 1 .. 15 loop
        x := case when (l & 8) <> 0 then p.c3 else ~p.c3 end & case when (l & 4) <> 0 then p.c2 else ~p.c2 end
           & case when (l & 2) <> 0 then p.c1 else ~p.c1 end & case when (l & 1) <> 0 then p.c0 else ~p.c0 end;
        if bit_count(x) > 0 then lvl := l; m := x; return next; end if;
    end loop;
end $$;

-- "An opaque cell above" for the 256 columns just above the section (cx, sy, cz): the columns whose cell in the lowest layer of that section is not a sky source (stored sky
-- level other than 15).  Sections above the stored layers are all sources.
create or replace function mc.light_carry_above(p_dim text, p_cx int, p_cz int, p_sy int) returns bit(256) language plpgsql stable as $$
declare
    v_min_sy int;
    k text; a bytea;
    p record;
begin
    select d.min_y >> 4 into v_min_sy from mc.dimension d where d.name = p_dim;
    select l.sky_kind, l.sky into k, a from mc.chunk_light l where l.dimension = p_dim and l.cx = p_cx and l.cz = p_cz and l.idx = p_sy - v_min_sy + 1;
    if not found then return repeat('0', 256)::bit(256); end if;
    if k = 'empty' or a is null then return repeat('1', 256)::bit(256); end if;
    if a = decode(repeat('ff', 2048), 'hex') then return repeat('0', 256)::bit(256); end if;
    select * into p from mc.light_planes(a);
    return substring(~(p.c0 & p.c1 & p.c2 & p.c3) from 1 for 256)::bit(256);
end $$;

-- The sky light stored for one cell (0 when the layer holds none).
create or replace function mc.light_sky_at(p_dim text, p_x int, p_y int, p_z int) returns int language plpgsql stable as $$
declare
    v_min_sy int;
    k text; a bytea; i int; b int;
begin
    select d.min_y >> 4 into v_min_sy from mc.dimension d where d.name = p_dim;
    select l.sky_kind, l.sky into k, a from mc.chunk_light l where l.dimension = p_dim and l.cx = p_x >> 4 and l.cz = p_z >> 4 and l.idx = (p_y >> 4) - v_min_sy + 1;
    if not found then return 15; end if;                                     -- above the stored layers: open sky
    if k <> 'data' or a is null then return 0; end if;
    i := ((p_y & 15) << 8) | ((p_z & 15) << 4) | (p_x & 15);
    b := get_byte(a, i >> 1);
    return case when (i & 1) = 1 then b >> 4 else b & 15 end;
end $$;

-- The highest cell below (x, y, z) whose state has dampening (it ends the sky sources of its column), or the cell below the world.
create or replace function mc.light_column_floor(p_dim text, p_x int, p_y int, p_z int) returns int language plpgsql stable as $$
declare
    v_min_y int;
    q int; ly int;
    s record;
    m record;
    pos int := (((p_z & 15) << 4) | (15 - (p_x & 15)));
begin
    select d.min_y into v_min_y from mc.dimension d where d.name = p_dim;
    for q in reverse ((p_y - 1) >> 4) .. (v_min_y >> 4) loop
        select cs.bits, cs.data, cs.palette into s from mc.chunk_section cs where cs.dimension = p_dim and cs.cx = p_x >> 4 and cs.cz = p_z >> 4 and cs.sy = q and cs.block_count > 0;
        if not found then continue; end if;
        select * into m from mc.light_secmasks(s.bits, s.data, s.palette);
        for ly in reverse (case when q = (p_y - 1) >> 4 then (p_y - 1) & 15 else 15 end) .. 0 loop
            if get_bit(m.cl, (ly << 8) | pos) = 0 then return q * 16 + ly; end if;
        end loop;
    end loop;
    return v_min_y - 1;
end $$;

drop function if exists mc.light_update(text, int[], int[], int[]);
create or replace function mc.light_update(p_dim text, p_x int[], p_y int[], p_z int[], p_sky boolean default true, p_blk boolean default true) returns int language plpgsql volatile set plan_cache_mode = force_generic_plan set jit = off as $$
declare
    v_min_y  int;
    v_height int;
    v_min_sy int;
    v_nsec   int;
    v_max_sy int;
    n_free   int;
    base     int;
    ly       int;
    lo       int;
    hi       int;
    yb       int[];
begin
    select d.min_y, d.height into v_min_y, v_height from mc.dimension d where d.name = p_dim;
    v_min_sy := v_min_y >> 4; v_nsec := v_height / 16; v_max_sy := v_min_sy + v_nsec - 1;
    perform mc.light_work_init();

    ---------------------------------------------------------------------------------------------------- the cube
    -- the column below a changed cell that was or becomes a sky source: the sources reach down to the next cell with dampening, so the cube extends there
    select array_agg(case when mc.light_sky_at(p_dim, u.x, u.y + 1, u.z) = 15 then mc.light_column_floor(p_dim, u.x, u.y, u.z) else u.y end order by u.o)
      into yb from unnest(p_x, p_y, p_z) with ordinality u(x, y, z, o);
    insert into lw_free
    select distinct qx, qy, qz
      from unnest(p_x, p_y, p_z, yb) u(x, y, z, yb)
      cross join lateral generate_series((u.x - 14) >> 4, (u.x + 14) >> 4) qx
      cross join lateral generate_series(greatest((least(u.y, u.yb) - 14) >> 4, v_min_sy - 1), least((u.y + 14) >> 4, v_max_sy + 1)) qy
      cross join lateral generate_series((u.z - 14) >> 4, (u.z + 14) >> 4) qz
     where exists (select 1 from mc.chunk c where c.dimension = p_dim and c.cx = qx and c.cz = qz);
    select count(*) into n_free from lw_free;
    if n_free = 0 then return 0; end if;
    if n_free > 120 then return -1; end if;
    insert into lw_frz
    select distinct f.cx + d.dx, f.sy + d.dy, f.cz + d.dz
      from lw_free f, (values (-1, 0, 0), (1, 0, 0), (0, 0, -1), (0, 0, 1), (0, -1, 0), (0, 1, 0)) d(dx, dy, dz)
     where f.sy + d.dy between v_min_sy - 1 and v_max_sy + 1
       and not exists (select 1 from lw_free g where g.cx = f.cx + d.dx and g.sy = f.sy + d.dy and g.cz = f.cz + d.dz)
       and exists (select 1 from mc.chunk c where c.dimension = p_dim and c.cx = f.cx + d.dx and c.cz = f.cz + d.dz);
    insert into lw_chunk (cx, cz, tgt, carry) select distinct f.cx, f.cz, true, repeat('0', 256)::bit(256) from lw_free f;

    -- the layers of the three chunks around must be as stored (a section turned empty or non-empty: the caller relights the chunks)
    insert into lw_ne
    select c.cx, c.cz, s.sy
      from (select distinct f.cx + dx as cx, f.cz + dz as cz from lw_chunk f, generate_series(-1, 1) dx, generate_series(-1, 1) dz) c
      join lateral (select cs.sy from mc.chunk_section cs where cs.dimension = p_dim and cs.cx = c.cx and cs.cz = c.cz and cs.block_count > 0 offset 0) s on true;
    if exists (
        with pres as (select distinct n.cx + dx as cx, n.cz + dz as cz, n.sy + dy as sy
                        from lw_ne n, generate_series(-1, 1) dx, generate_series(-1, 1) dz, generate_series(-1, 1) dy),
        want as (select c.cx, c.cz, g.idx from lw_chunk c cross join generate_series(0, v_nsec + 1) g(idx)
                  join pres p on p.cx = c.cx and p.cz = c.cz and p.sy = v_min_sy + g.idx - 1)
        select 1 from want w full join (select l.cx, l.cz, l.idx from mc.chunk_light l join lw_chunk c on c.cx = l.cx and c.cz = l.cz where l.dimension = p_dim) h
                                      on h.cx = w.cx and h.cz = w.cz and h.idx = w.idx
         where w.idx is null or h.idx is null) then
        return -1;
    end if;

    ---------------------------------------------------------------------------------------------------- shapes of the cells involved
    insert into lw_pal
    select p.cx, p.sy, p.cz, coalesce(bool_or(l.emission > 0), false) or cardinality(s.palette) = 0, coalesce(bool_or(l.shaped), false) or cardinality(s.palette) = 0
      from (select cx, sy, cz from lw_free union select cx, sy, cz from lw_frz) p
      join lateral (select cs.palette from mc.chunk_section cs where cs.dimension = p_dim and cs.cx = p.cx and cs.cz = p.cz and cs.sy = p.sy and cs.block_count > 0 offset 0) s on true
      left join lateral unnest(s.palette) u(nm) on true
      left join mc.light_state l on l.name = u.nm
     group by p.cx, p.sy, p.cz, s.palette;
    perform mc.light_shapes_prepare(p_dim);

    ---------------------------------------------------------------------------------------------------- sections
    insert into lw_sec (i, cx, sy, cz, pass, src, em_lvl, em_mask, sh, cl, stored)
    select row_number() over (order by m.cx, m.sy, m.cz), m.cx, m.sy, m.cz, ~coalesce(m.op, mc.lk_zero()), null, m.em_lvl, m.em_mask, m.sh, coalesce(m.cl, mc.lk_ones()), m.ssy is not null
      from (select f.cx, f.sy, f.cz, s.ssy, s.op, s.cl, s.em_lvl, s.em_mask, s.sh
              from lw_free f
              left join lateral (select cs.sy as ssy, mm.op, mm.cl, mm.em_lvl, mm.em_mask, mm.sh
                                   from mc.chunk_section cs, lateral mc.light_secmasks(cs.bits, cs.data, cs.palette) mm
                                  where cs.dimension = p_dim and cs.cx = f.cx and cs.cz = f.cz and cs.sy = f.sy and cs.block_count > 0 limit 1) s on true) m;
    select coalesce(max(i), 0) into base from lw_sec;
    insert into lw_sec (i, cx, sy, cz, pass, stored)
    select base + row_number() over (order by z.cx, z.sy, z.cz), z.cx, z.sy, z.cz, mc.lk_zero(), true from lw_frz z;
    perform mc.light_link();
    perform mc.light_shapes_apply();

    ---------------------------------------------------------------------------------------------------- sky sources of the free sections, from the top down
    select min(sy), max(sy) into lo, hi from lw_free;
    if p_sky then
    for ly in reverse hi .. lo loop
        with act as (
            select s.i, s.cx, s.cz, s.cl, c.carry as chain, f.cx is not null as above_free
              from lw_sec s join lw_free g on g.cx = s.cx and g.sy = s.sy and g.cz = s.cz
              join lw_chunk c on c.cx = s.cx and c.cz = s.cz
              left join lw_free f on f.cx = s.cx and f.sy = s.sy + 1 and f.cz = s.cz
             where s.sy = ly),
        calc as materialized (
            select a.i, a.cx, a.cz,
                   a4 | repeat((case when a.above_free then a.chain else mc.light_carry_above(p_dim, a.cx, a.cz, ly + 1) end)::text, 16)::bit(4096) as a
              from act a
              left join lw_occ qo on qo.cx = a.cx and qo.sy = ly and qo.cz = a.cz and qo.side = 1,
                   lateral (select ~a.cl | coalesce(qo.m, mc.lk_zero()) as q) q,
                   lateral (select q.q | (q.q << 256) as a1) l1,
                   lateral (select a1 | (a1 << 512) as a2) l2,
                   lateral (select a2 | (a2 << 1024) as a3) l3,
                   lateral (select a3 | (a3 << 2048) as a4) l4),
        up as (update lw_sec s set src = ~c.a from calc c where s.i = c.i returning 1)
        update lw_chunk k set carry = substring(c.a from 1 for 256)::bit(256) from calc c where k.cx = c.cx and k.cz = c.cz;
    end loop;
    end if;

    ---------------------------------------------------------------------------------------------------- waves: sky, then block (frozen cells start waves at their stored level)
    if p_sky then
        insert into lw_em select s.i, 15, s.src from lw_sec s where s.src is not null and bit_count(s.src) > 0;
        insert into lw_em
        select s.i, v.lvl, v.m
          from lw_sec s join lw_frz z on z.cx = s.cx and z.sy = s.sy and z.cz = s.cz
          join mc.chunk_light l on l.dimension = p_dim and l.cx = s.cx and l.cz = s.cz and l.idx = s.sy - v_min_sy + 1
          cross join lateral mc.light_levels(l.sky) v
         where l.sky_kind = 'data';
        perform mc.light_waves(1);
        delete from lw_em;
    end if;
    if p_blk then
    insert into lw_em select s.i, u.l, u.m from lw_sec s join lw_free f on f.cx = s.cx and f.sy = s.sy and f.cz = s.cz, unnest(s.em_lvl, s.em_mask) u(l, m) where s.em_lvl is not null;
    insert into lw_em
    select s.i, v.lvl, v.m
      from lw_sec s join lw_frz z on z.cx = s.cx and z.sy = s.sy and z.cz = s.cz
      join mc.chunk_light l on l.dimension = p_dim and l.cx = s.cx and l.cz = s.cz and l.idx = s.sy - v_min_sy + 1
      cross join lateral mc.light_levels(l.block) v
     where l.block_kind = 'data';
    perform mc.light_waves(2);
    end if;

    ---------------------------------------------------------------------------------------------------- compare and write the free sections
    insert into lw_out
    select s.cx, s.cz, s.sy - v_min_sy + 1,
           case when not p_sky then l.sky_kind when bit_count(rs.c0 | rs.c1 | rs.c2 | rs.c3) > 0 then 'data' when l.sky_kind = 'data' then 'data' else 'empty' end,
           case when not p_sky then l.sky
                when bit_count(rs.c0 | rs.c1 | rs.c2 | rs.c3) = 0 then (case when l.sky_kind = 'data' then decode(repeat('00', 2048), 'hex') end)
                when bit_count(rs.c0 & rs.c1 & rs.c2 & rs.c3) = 4096 then mc.light_array_uniform(15)
                else mc.light_array(rs.c3, rs.c2, rs.c1, rs.c0) end,
           case when not p_blk then l.block_kind when bit_count(rb.c0 | rb.c1 | rb.c2 | rb.c3) > 0 then 'data' when l.block_kind = 'data' then 'data' else 'empty' end,
           case when not p_blk then l.block
                when bit_count(rb.c0 | rb.c1 | rb.c2 | rb.c3) = 0 then (case when l.block_kind = 'data' then decode(repeat('00', 2048), 'hex') end)
                when bit_count(rb.c0 & rb.c1 & rb.c2 & rb.c3) = 4096 then mc.light_array_uniform(15)
                else mc.light_array(rb.c3, rb.c2, rb.c1, rb.c0) end
      from lw_sec s join lw_free f on f.cx = s.cx and f.sy = s.sy and f.cz = s.cz
      left join lw_run rs on rs.kind = 1 and rs.i = s.i
      left join lw_run rb on rb.kind = 2 and rb.i = s.i
      join mc.chunk_light l on l.dimension = p_dim and l.cx = s.cx and l.cz = s.cz and l.idx = s.sy - v_min_sy + 1;
    perform mc.light_delta_from_out(p_dim);
    update mc.chunk_light l set sky_kind = o.sky_kind, sky = o.sky, block_kind = o.block_kind, block = o.block
      from lw_out o
     where l.dimension = p_dim and l.cx = o.cx and l.cz = o.cz and l.idx = o.idx and (l.sky_kind, l.sky, l.block_kind, l.block) is distinct from (o.sky_kind, o.sky, o.block_kind, o.block);
    update mc.chunk k set light_ws = null, light_top = null from lw_chunk c where k.dimension = p_dim and k.cx = c.cx and k.cz = c.cz;
    return (select count(*)::int from lw_delta);
end $$;
