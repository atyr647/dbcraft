-- Light engine, part 2: bit-set building blocks.  See docs/LIGHT.md.
--
-- The engine works on 4,096-bit strings (PostgreSQL bit(4096)), one per 16x16x16 section and property ("layout M"): the bit of the cell (x, y, z) of a section sits at
-- string position  (y << 8) | (z << 4) | (15 - x)  (counted from the left, 0-based).  That is the order in which the 4-bit palette sections store their cells once their
-- data is written as a hex string (entry i of a long is the nibble 15 - i % 16 of its big-endian hex form), so the common case needs no permutation at all.
-- Shifts are whole-string shifts: S << k is the string whose position p holds S[p + k], S >> k the one whose position p holds S[p - k].
--   neighbour at x - 1 of position p: p + 1       x + 1: p - 1       z - 1: p - 16       z + 1: p + 16       y - 1: p - 256       y + 1: p + 256

-- cell masks (as functions of no argument: the planner folds them into constants)
create or replace function mc.lk_x0()  returns bit(4096) language sql immutable parallel safe as $$ select repeat('0000000000000001', 256)::bit(4096) $$;           -- cells with x = 0
create or replace function mc.lk_x15() returns bit(4096) language sql immutable parallel safe as $$ select repeat('1000000000000000', 256)::bit(4096) $$;           -- x = 15
create or replace function mc.lk_z0()  returns bit(4096) language sql immutable parallel safe as $$ select repeat(repeat('1', 16) || repeat('0', 240), 16)::bit(4096) $$;   -- z = 0
create or replace function mc.lk_z15() returns bit(4096) language sql immutable parallel safe as $$ select repeat(repeat('0', 240) || repeat('1', 16), 16)::bit(4096) $$;   -- z = 15
create or replace function mc.lk_y0()  returns bit(4096) language sql immutable parallel safe as $$ select (repeat('1', 256) || repeat('0', 3840))::bit(4096) $$;      -- y = 0
create or replace function mc.lk_y15() returns bit(4096) language sql immutable parallel safe as $$ select (repeat('0', 3840) || repeat('1', 256))::bit(4096) $$;      -- y = 15
create or replace function mc.lk_ones() returns bit(4096) language sql immutable parallel safe as $$ select repeat('1', 4096)::bit(4096) $$;
create or replace function mc.lk_msb() returns bit(4096) language sql immutable parallel safe as $$ select ('1' || repeat('0', 4095))::bit(4096) $$;   -- only position 0 set
create or replace function mc.lk_zero() returns bit(4096) language sql immutable parallel safe as $$ select repeat('0', 4096)::bit(4096) $$;

-- Palette classification: per palette entry (in order) its light dampening, emission and whether it uses its occlusion shape.  Names the table does not know count as air.
create or replace function mc.light_pal(p_palette text[], out damp int[], out emission int[], out shaped boolean[]) language sql stable parallel safe as $$
  select coalesce(array_agg(coalesce(l.damp, 0)::int order by p.o), '{}'), coalesce(array_agg(coalesce(l.emission, 0)::int order by p.o), '{}'),
         coalesce(array_agg(coalesce(l.shaped, false) order by p.o), '{}')
    from unnest(p_palette) with ordinality p(n, o) left join mc.light_state l on l.name = p.n $$;

-- The masks of one section as the engine needs them:
--   op        cells whose state has dampening 15 (light never enters them)
--   cl        cells whose state has dampening 0 (sky light passes without loss; the others, 1 and 15, end a sky source column)
--   em_lvl    the distinct emission levels (1 .. 15) of the section, em_mask the cells of each
--   sh        cells whose state uses its occlusion shape (NULL when there are none)
-- p_bits / p_data / p_palette are the stored columns (palette = {} means the data holds global state ids).
-- Cost: a section of one class (or one state) needs no unpacking; a 4-bit palette section costs one hex string and one translate() per class that is not implied by
-- the others (about 90 us each); other widths unpack the entries (about 3 ms).
create or replace function mc.light_secmasks(p_bits int, p_data bytea, p_palette text[], out op bit(4096), out cl bit(4096), out em_lvl int[], out em_mask bit(4096)[], out sh bit(4096))
language plpgsql stable strict parallel safe set plan_cache_mode = force_generic_plan as $$
declare
    pd int[]; pe int[]; ps boolean[];
    n int := cardinality(p_palette);
    hx text; lv int;
    has0 boolean; has1 boolean; has15 boolean; hassh boolean;
    map_op text; map_cl text; map_sh text; map_em text;
    codes text;
    ent int[];
begin
    em_lvl := '{}'; em_mask := '{}';
    if n = 0 then                                                         -- global palette: the entries are state ids
        ent := mc.unpack_longs(p_data, p_bits, 4096);
        select string_agg(case when coalesce(l.damp, 0) = 15 then '1' else '0' end, '' order by (u.i - 1) # 15),
               string_agg(case when coalesce(l.damp, 0) = 0 then '1' else '0' end, '' order by (u.i - 1) # 15),
               string_agg(case when coalesce(l.shaped, false) then '1' else '0' end, '' order by (u.i - 1) # 15)
          into map_op, map_cl, map_sh
          from unnest(ent) with ordinality u(e, i) left join mc.light_state l on l.sid = u.e;
        op := map_op::bit(4096); cl := map_cl::bit(4096); sh := case when map_sh like '%1%' then map_sh::bit(4096) end;
        for lv in select distinct l.emission from unnest(ent) u(e) join mc.light_state l on l.sid = u.e and l.emission > 0 order by 1 loop
            select string_agg(case when coalesce(l.emission, 0) = lv then '1' else '0' end, '' order by (u.i - 1) # 15) into map_em
              from unnest(ent) with ordinality u(e, i) left join mc.light_state l on l.sid = u.e;
            em_lvl := em_lvl || lv; em_mask := em_mask || map_em::bit(4096);
        end loop;
        return;
    end if;
    select * into pd, pe, ps from mc.light_pal(p_palette);
    has0 := 0 = any(pd); has1 := 1 = any(pd); has15 := 15 = any(pd); hassh := true = any(ps);
    if p_bits = 0 or ((has0::int + has1::int + has15::int) = 1 and (select count(distinct e) from unnest(pe) e) = 1 and (not hassh or ps = array_fill(true, array[n]))) then
        -- one state, or every state of the palette in the same class: no unpacking
        op := case when has15 then mc.lk_ones() else mc.lk_zero() end;
        cl := case when has0 then mc.lk_ones() else mc.lk_zero() end;
        if pe[1] > 0 then em_lvl := array[pe[1]]; em_mask := array[mc.lk_ones()]; end if;
        sh := case when ps[1] then mc.lk_ones() end;
        return;
    end if;
    if p_bits = 4 then
        hx := encode(p_data, 'hex');
        select rpad(string_agg(case when d = 15 then '1' else '0' end, '' order by o), 16, '0'), rpad(string_agg(case when d = 0 then '1' else '0' end, '' order by o), 16, '0'),
               rpad(string_agg(case when s then '1' else '0' end, '' order by o), 16, '0')
          into map_op, map_cl, map_sh from unnest(pd, ps) with ordinality u(d, s, o);
        op := case when has15 then translate(hx, '0123456789abcdef', map_op)::bit(4096) else mc.lk_zero() end;
        cl := case when not has0 then mc.lk_zero() when not has1 then ~op else translate(hx, '0123456789abcdef', map_cl)::bit(4096) end;
        if hassh then sh := translate(hx, '0123456789abcdef', map_sh)::bit(4096); end if;
        for lv in select distinct e from unnest(pe) e where e > 0 order by 1 loop
            select rpad(string_agg(case when e = lv then '1' else '0' end, '' order by o), 16, '0') into map_em from unnest(pe) with ordinality u(e, o);
            em_lvl := em_lvl || lv; em_mask := em_mask || translate(hx, '0123456789abcdef', map_em)::bit(4096);
        end loop;
        return;
    end if;
    -- other widths: unpack the entries once, then one pass builds a code string (one character per cell, layout M) for all classes
    ent := mc.unpack_longs(p_data, p_bits, 4096);
    select string_agg(case when pd[ent[(p # 15) + 1] + 1] = 15 then '2' when pd[ent[(p # 15) + 1] + 1] = 1 then '1' else '0' end, '' order by p) into codes from generate_series(0, 4095) p;
    op := translate(codes, '012', '001')::bit(4096);
    cl := translate(codes, '012', '100')::bit(4096);
    if hassh then
        select string_agg(case when ps[ent[(p # 15) + 1] + 1] then '1' else '0' end, '' order by p) into map_sh from generate_series(0, 4095) p;
        sh := map_sh::bit(4096);
    end if;
    for lv in select distinct e from unnest(pe) e where e > 0 order by 1 loop
        select string_agg(case when pe[ent[(p # 15) + 1] + 1] = lv then '1' else '0' end, '' order by p) into map_em from generate_series(0, 4095) p;
        em_lvl := em_lvl || lv; em_mask := em_mask || map_em::bit(4096);
    end loop;
end $$;

-- The cells of a section whose state uses its occlusion shape, with the six face-shape ids of the state (order DOWN UP NORTH SOUTH WEST EAST): idx = (y << 8) | (z << 4) | x.
create or replace function mc.light_shaped_cells(p_bits int, p_data bytea, p_palette text[]) returns table (idx int, f smallint[]) language sql stable strict parallel safe as $$
  select u.i - 1, array[l.f_down, l.f_up, l.f_north, l.f_south, l.f_west, l.f_east]
    from unnest(mc.unpack_longs(p_data, p_bits, 4096)) with ordinality u(e, i)
    join (select p.o - 1 as pidx, ls.f_down, ls.f_up, ls.f_north, ls.f_south, ls.f_west, ls.f_east
            from unnest(p_palette) with ordinality p(n, o) join mc.light_state ls on ls.name = p.n and ls.shaped) l on l.pidx = u.e $$;
