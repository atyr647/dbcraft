-- World dynamics, part 2: reading a block of sections of the world into one array of state ids.  The engine (sql/882) works on that array and writes the changes back at
-- the end of its step.
--
--   mc.dyn_decode(bits, data, palette_ids)                      a whole section as 4,096 state ids, 1.3 ms for a 4-bit section
--   mc.dyn_secs(dim, cx0, cx1, sy0, sy1, cz0, cz1, needed slots)  ->  int4[][]   row 1 is the barrier, row i + 1 the section of slot needed[i] (slot = ((sy - sy0) * (cz1 - cz0 + 1) +
--                                                              (cz - cz0)) * (cx1 - cx0 + 1) + (cx - cx0) + 1, ascending), and column i + 1 its entry with storage index i = y << 8 | z << 4 | x
-- A section of a chunk that does not exist reads as the barrier state (id n of mc.dyn_vec: a full block that nothing replaces; fluids do not flow into chunks that do not
-- exist, where the vanilla server would have generated them first), a missing section of an existing chunk as air, and a section above or below the world as void air.
-- Only the needed sections are decoded; the engine's grid map (mc.dyn_at) sends every other slot to row 1, the barrier (nothing looks at those cells).

create or replace function mc.dyn_decode(p_bits int, d bytea, pal int4[]) returns int4[] language sql immutable parallel safe as $$
  select case when p_bits = 0 then array_fill(coalesce(pal[1], 0), array[4096])
    when p_bits = 4 then
      array(select case when cardinality(pal) = 0 then e else pal[e + 1] end
              from (select (get_byte(d, (i >> 4) * 8 + 7 - ((i & 15) >> 1)) >> ((i & 1) * 4)) & 15 as e, i from generate_series(0, 4095) i) t order by i)
    else
      array(select case when cardinality(pal) = 0 then e else pal[e + 1] end
              from (select ((((get_byte(d, b))
                            | ((case when b - 1 >= base then get_byte(d, b - 1) else 0 end) << 8)
                            | ((case when b - 2 >= base then get_byte(d, b - 2) else 0 end) << 16)) >> (p % 8)) & ((1 << p_bits) - 1)) as e, i
                      from (select i, base, p, base + 7 - p / 8 as b
                              from (select i, (i / (64 / p_bits)) * 8 as base, (i % (64 / p_bits)) * p_bits as p from generate_series(0, 4095) i) q) r) t
             order by i)
  end $$;

-- the decoded sections, kept while their chunk's version is unchanged (every edit of a chunk bumps its version): a decode costs 1.3 ms, reading the cached array 30 us.
-- Unlogged: it is derived data.  mc.dyn_secs fills it on demand.
create unlogged table if not exists mc.dyn_sec_cache (dimension text not null, cx int not null, sy int not null, cz int not null, version bigint not null, cells int4[] not null, primary key (dimension, cx, cz, sy));

create or replace function mc.dyn_secs(p_dim text, cx0 int, cx1 int, sy0 int, sy1 int, cz0 int, cz1 int, p_need int[]) returns int4[] language plpgsql volatile as $$
declare
    v    mc.dyn_vec%rowtype;
    d    mc.dimension%rowtype;
    smin int; smax int;
    f_bar int4[]; f_air int4[]; f_void int4[];
    res  int4[];
    ncx  int := cx1 - cx0 + 1; ncz int := cz1 - cz0 + 1;
begin
    select * into v from mc.dyn_vec;
    select * into d from mc.dimension where name = p_dim;
    smin := d.min_y >> 4; smax := (d.min_y + d.height - 1) >> 4;
    f_bar := array_fill(v.n, array[4096]); f_air := array_fill(v.k[1], array[4096]); f_void := array_fill(v.k[2], array[4096]);
    -- decode and cache the real sections that are not cached (or whose chunk changed); stable-function rules do not allow this write in a STABLE function, hence volatile below
    select array_agg(r.row order by r.ord) into res from (
        select 0 as ord, f_bar as row
        union all
        select n.i::int,
               case when c.cx is null then f_bar
                    when t.sy < smin or t.sy > smax then f_void
                    when s.sy is null then f_air
                    when k.version = c.version then k.cells
                    else mc.dyn_decode_cached(p_dim, t.cx, t.sy, t.cz, c.version, s.bits, s.data, s.palette) end
          from unnest(p_need) with ordinality n(slot, i)
          cross join lateral (select sy0 + (n.slot - 1) / (ncz * ncx) as sy, cz0 + ((n.slot - 1) / ncx) % ncz as cz, cx0 + (n.slot - 1) % ncx as cx) t
          left join mc.chunk c on c.dimension = p_dim and c.cx = t.cx and c.cz = t.cz
          left join mc.chunk_section s on s.dimension = p_dim and s.cx = t.cx and s.cz = t.cz and s.sy = t.sy
          left join mc.dyn_sec_cache k on k.dimension = p_dim and k.cx = t.cx and k.cz = t.cz and k.sy = t.sy) r;
    return res;
end $$;

-- decode a section and remember it (the section row's palette names become state ids)
create or replace function mc.dyn_decode_cached(p_dim text, p_cx int, p_sy int, p_cz int, p_version bigint, p_bits int, p_data bytea, p_palette text[]) returns int4[] language plpgsql volatile as $$
declare cells int4[];
begin
    cells := mc.dyn_decode(p_bits, p_data, case when cardinality(p_palette) = 0 then '{}'::int4[]
                                                  else array(select b.state_id from unnest(p_palette) with ordinality p(nm, o) join ref.block_state b on b.name = p.nm order by o) end);
    insert into mc.dyn_sec_cache (dimension, cx, sy, cz, version, cells) values (p_dim, p_cx, p_sy, p_cz, p_version, cells)
    on conflict (dimension, cx, cz, sy) do update set version = excluded.version, cells = excluded.cells;
    return cells;
end $$;
