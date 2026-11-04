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
    vn   int; vk1 int; vk2 int;
    d    mc.dimension%rowtype;
    smin int; smax int;
    f_bar int4[]; f_air int4[]; f_void int4[];
    res  int4[];
    ncx  int := cx1 - cx0 + 1; ncz int := cz1 - cz0 + 1;
    -- mc.dyn_nocache = on: decode every section from the stored rows and leave the cache alone (the statement trigger of sql/885 runs while a fill is still writing: a chunk's version
    -- is bumped after its events are recorded, so a cached section can be older than the rows)
    use_cache boolean := coalesce(current_setting('mc.dyn_nocache', true), 'off') <> 'on';
begin
    select n, k[1], k[2] into vn, vk1, vk2 from mc.dyn_vec;                       -- (only these: the other arrays are large)
    select * into d from mc.dimension where name = p_dim;
    smin := d.min_y >> 4; smax := (d.min_y + d.height - 1) >> 4;
    f_bar := array_fill(vn, array[4096]); f_air := array_fill(vk1, array[4096]); f_void := array_fill(vk2, array[4096]);
    -- decode and cache the real sections that are not cached (or whose chunk changed); stable-function rules do not allow this write in a STABLE function, hence volatile below
    select array_agg(r.row order by r.ord) into res from (
        select 0 as ord, f_bar as row
        union all
        select n.i::int,
               case when c.cx is null then f_bar
                    when t.sy < smin or t.sy > smax then f_void
                    when s.sy is null then f_air
                    when use_cache and kv.version = c.version and k.cells is not null then k.cells
                    when use_cache then mc.dyn_decode_cached(p_dim, t.cx, t.sy, t.cz, c.version, s.bits, s.data, s.palette)
                    else mc.dyn_decode_plain(s.bits, s.data, s.palette) end
          from unnest(p_need) with ordinality n(slot, i)
          cross join lateral (select sy0 + (n.slot - 1) / (ncz * ncx) as sy, cz0 + ((n.slot - 1) / ncx) % ncz as cz, cx0 + (n.slot - 1) % ncx as cx) t
          left join mc.chunk c on c.dimension = p_dim and c.cx = t.cx and c.cz = t.cz
          left join mc.chunk_section s on s.dimension = p_dim and s.cx = t.cx and s.cz = t.cz and s.sy = t.sy
          left join mc.dyn_sec_ver kv on kv.dimension = p_dim and kv.cx = t.cx and kv.cz = t.cz and kv.sy = t.sy
          left join mc.dyn_sec_cache k on k.dimension = p_dim and k.cx = t.cx and k.cz = t.cz and k.sy = t.sy) r;
    return res;
end $$;

-- which chunk version each cached section is valid for (narrow rows: a chunk edit bumps the version of the chunk's cached sections that were not written, 30 bytes each, not a 16 KB row)
create unlogged table if not exists mc.dyn_sec_ver (dimension text not null, cx int not null, sy int not null, cz int not null, version bigint not null, primary key (dimension, cx, cz, sy));
alter table mc.dyn_sec_cache alter column cells set storage external;       -- no compression: reading and writing 16 KB rows should not cost a pglz pass

-- decode a section and remember it (the section row's palette names become state ids)
-- A section made of 16 uniform horizontal layers (a flat or superflat world, a floor, a fill: every layer is one state) is decoded without looking at 4,096 entries: each layer of 256 four-bit
-- entries is 128 bytes, all equal to one byte with both nibbles the same.  Null when a layer is not uniform (or the section is not 4 bits).
create or replace function mc.dyn_decode_layered(p_bits int, p_data bytea, pal int4[]) returns int4[] language plpgsql immutable parallel safe as $$
declare res int4[] := '{}'; l int; s bytea; b int; v int;
begin
    if p_bits <> 4 or length(p_data) <> 2048 then return null; end if;
    for l in 0 .. 15 loop
        s := substring(p_data from l * 128 + 1 for 128);
        b := get_byte(s, 0);
        if (b >> 4) <> (b & 15) or encode(s, 'hex') <> repeat(lpad(to_hex(b), 2, '0'), 128) then return null; end if;
        v := b & 15;
        res := res || array_fill(case when cardinality(pal) = 0 then v else pal[v + 1] end, array[256]);
    end loop;
    return res;
end $$;

create or replace function mc.dyn_decode_plain(p_bits int, p_data bytea, p_palette text[]) returns int4[] language sql stable as $$
  select coalesce(mc.dyn_decode_layered(p_bits, p_data, q.pal), mc.dyn_decode(p_bits, p_data, q.pal))
    from (select case when cardinality(p_palette) = 0 then '{}'::int4[]
                      else array(select b.state_id from unnest(p_palette) with ordinality p(nm, o) join ref.block_state b on b.name = p.nm order by o) end as pal) q $$;

create or replace function mc.dyn_decode_cached(p_dim text, p_cx int, p_sy int, p_cz int, p_version bigint, p_bits int, p_data bytea, p_palette text[]) returns int4[] language plpgsql volatile as $$
declare cells int4[];
begin
    cells := mc.dyn_decode_plain(p_bits, p_data, p_palette);
    insert into mc.dyn_sec_cache (dimension, cx, sy, cz, version, cells) values (p_dim, p_cx, p_sy, p_cz, p_version, cells)
    on conflict (dimension, cx, cz, sy) do update set version = excluded.version, cells = excluded.cells;
    insert into mc.dyn_sec_ver (dimension, cx, sy, cz, version) values (p_dim, p_cx, p_sy, p_cz, p_version)
    on conflict (dimension, cx, cz, sy) do update set version = excluded.version;
    return cells;
end $$;
