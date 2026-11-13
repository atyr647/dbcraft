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
create or replace function mc.light_secmasks(p_bits int, p_data bytea, p_palette text[], out op bit(4096), out cl bit(4096), out em_lvl int[], out em_mask bit(4096)[], out sh bit(4096))
language plpgsql stable strict parallel safe set plan_cache_mode = force_generic_plan as $$
declare
    pd int[]; pe int[]; ps boolean[];
    n int := cardinality(p_palette);
    hx text; k int; lv int;
    m_op text; m_cl text; m_sh text; m_em text;
    map_op text; map_cl text; map_sh text; map_em text;
begin
    if n = 0 then                                                         -- global palette: the entries are state ids
        select string_agg(case when coalesce(l.damp, 0) = 15 then '1' else '0' end, '' order by (u.i - 1) # 15),
               string_agg(case when coalesce(l.damp, 0) = 0 then '1' else '0' end, '' order by (u.i - 1) # 15),
               string_agg(case when coalesce(l.shaped, false) then '1' else '0' end, '' order by (u.i - 1) # 15)
          into m_op, m_cl, m_sh
          from unnest(mc.unpack_longs(p_data, p_bits, 4096)) with ordinality u(e, i) left join mc.light_state l on l.sid = u.e;
        op := m_op::bit(4096); cl := m_cl::bit(4096); sh := case when m_sh like '%1%' then m_sh::bit(4096) end;
        em_lvl := '{}'; em_mask := '{}';
        for lv in select distinct l.emission from unnest(mc.unpack_longs(p_data, p_bits, 4096)) u(e) join mc.light_state l on l.sid = u.e and l.emission > 0 order by 1 loop
            select string_agg(case when coalesce(l.emission, 0) = lv then '1' else '0' end, '' order by (u.i - 1) # 15) into m_em
              from unnest(mc.unpack_longs(p_data, p_bits, 4096)) with ordinality u(e, i) left join mc.light_state l on l.sid = u.e;
            em_lvl := em_lvl || lv; em_mask := em_mask || m_em::bit(4096);
        end loop;
        return;
    end if;
    select * into pd, pe, ps from mc.light_pal(p_palette);
    em_lvl := '{}'; em_mask := '{}';
    if p_bits = 0 or (pd = array_fill(pd[1], array[n]) and pe = array_fill(pe[1], array[n]) and ps = array_fill(ps[1], array[n])) then
        -- one state, or every state of the palette in the same class: no unpacking
        op := case when pd[1] = 15 then mc.lk_ones() else mc.lk_zero() end;
        cl := case when pd[1] = 0 then mc.lk_ones() else mc.lk_zero() end;
        if pe[1] > 0 then em_lvl := array[pe[1]]; em_mask := array[mc.lk_ones()]; end if;
        sh := case when ps[1] then mc.lk_ones() end;
        return;
    end if;
    if p_bits = 4 then
        hx := encode(p_data, 'hex');
        map_op := ''; map_cl := ''; map_sh := '';
        for k in 1 .. 16 loop
            if k <= n then
                map_op := map_op || case when pd[k] = 15 then '1' else '0' end;
                map_cl := map_cl || case when pd[k] = 0 then '1' else '0' end;
                map_sh := map_sh || case when ps[k] then '1' else '0' end;
            else
                map_op := map_op || '0'; map_cl := map_cl || '0'; map_sh := map_sh || '0';
            end if;
        end loop;
        op := translate(hx, '0123456789abcdef', map_op)::bit(4096);
        cl := translate(hx, '0123456789abcdef', map_cl)::bit(4096);
        if map_sh like '%1%' then sh := translate(hx, '0123456789abcdef', map_sh)::bit(4096); end if;
        for lv in select distinct e from unnest(pe) e where e > 0 order by 1 loop
            map_em := '';
            for k in 1 .. 16 loop map_em := map_em || case when k <= n and pe[k] = lv then '1' else '0' end; end loop;
            em_lvl := em_lvl || lv; em_mask := em_mask || translate(hx, '0123456789abcdef', map_em)::bit(4096);
        end loop;
        return;
    end if;
    -- other widths: unpack the entries (about 2 ms per section)
    select string_agg(case when pd[u.e + 1] = 15 then '1' else '0' end, '' order by (u.i - 1) # 15),
           string_agg(case when pd[u.e + 1] = 0 then '1' else '0' end, '' order by (u.i - 1) # 15),
           string_agg(case when ps[u.e + 1] then '1' else '0' end, '' order by (u.i - 1) # 15)
      into m_op, m_cl, m_sh
      from unnest(mc.unpack_longs(p_data, p_bits, 4096)) with ordinality u(e, i);
    op := m_op::bit(4096); cl := m_cl::bit(4096); sh := case when m_sh like '%1%' then m_sh::bit(4096) end;
    for lv in select distinct e from unnest(pe) e where e > 0 order by 1 loop
        select string_agg(case when pe[u.e + 1] = lv then '1' else '0' end, '' order by (u.i - 1) # 15) into m_em
          from unnest(mc.unpack_longs(p_data, p_bits, 4096)) with ordinality u(e, i);
        em_lvl := em_lvl || lv; em_mask := em_mask || m_em::bit(4096);
    end loop;
end $$;
