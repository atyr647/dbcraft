-- Reading and editing blocks.
--
--   mc.get_block(dim, x, y, z)                         one block; NULL when the chunk does not exist, 'minecraft:air' for a missing section
--   mc.set_block(dim, x, y, z, block)                  one edit; true when the block changed
--   mc.set_blocks(dim, xs[], ys[], zs[], blocks[])     many edits in one set-based pass (sql/290); returns blocks changed
--   mc.fill(dim, x1, y1, z1, x2, y2, z2, block)        a box (inclusive corners); whole sections are replaced without unpacking; returns blocks covered
--   mc.blocks                                          readable view of every non-air block, with INSTEAD OF INSERT/UPDATE/DELETE triggers
--   mc.blocks_in(dim, x1, y1, z1, x2, y2, z2)          the same restricted to a box: touches only the sections the box overlaps (use this for large worlds)
--   mc.block_at(dim, x, y, z)                          a single row of that shape, for any position (air included)
--
-- "block" accepts a full state name ('minecraft:oak_log[axis=x]') or a bare block name (its default state).
-- Every edit bumps mc.chunk.version (invalidating the cached packet), marks the chunk dirty (heightmaps and light are recomputed on the next send)
-- and queues a row in mc.block_event.

-- Bits per entry for a palette of n states: 0 single value, 4 .. 8 palette, else the global palette (direct state ids, 16 bits).
create or replace function mc.block_bits_for(n int) returns int language sql stable parallel safe as $$
  select case when n <= 1 then 0 when mc.ceillog2(n) <= 4 then 4 when mc.ceillog2(n) <= 8 then mc.ceillog2(n) else mc.global_block_bits() end $$;

create or replace function mc.get_block(p_dim text, x int, y int, z int) returns text language plpgsql stable as $$
declare
    s record;
    e int;
begin
    select cs.bits, cs.palette, cs.data into s from mc.chunk_section cs
     where cs.dimension = p_dim and cs.cx = x >> 4 and cs.cz = z >> 4 and cs.sy = y >> 4;
    if not found then
        perform 1 from mc.chunk c where c.dimension = p_dim and c.cx = x >> 4 and c.cz = z >> 4;
        return case when found then 'minecraft:air' end;
    end if;
    if s.bits = 0 then return s.palette[1]; end if;
    e := mc.entry_at(s.bits, s.data, mc.section_idx(x, y, z));
    return case when cardinality(s.palette) = 0 then mc.state_name(e) else s.palette[e + 1] end;
end $$;

-- The result of mc.edit_section_core: how many blocks changed and, for each change in order, its index inside the section and the old and new block.
do $$
begin
    create type mc.sec_edit_result as (changed int, ev_idx int[], ev_old text[], ev_new text[]);
exception when duplicate_object then null;
end $$;

-- The core of an edit: reads the section (creating it in memory if it does not exist), grows the palette with the names of this batch, applies the edits at the right bit
-- width (few edits: only the affected longs; many: unpacked once; width change: repacked once) and writes the section.  Returns the changes; it does NOT touch the chunk
-- row, the heightmaps or the event queue, which the callers handle (mc.edit_section for one section, mc.set_blocks for many sections at once with per-chunk bookkeeping).
-- p_dn / p_cn: distinct raw names and their canonical state names (resolved by the caller, which also checked the dimension and the chunk).
create or replace function mc.edit_section_core(p_dim text, p_cx int, p_sy int, p_cz int, p_idx int[], p_names text[], p_dn text[], p_cn text[], p_default_biome text)
returns mc.sec_edit_result language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    sec_ok    boolean;
    v_bc      int;
    v_fc      int;
    v_pal     text[];
    v_bits    int;
    v_data    bytea;
    v_bpal    text[];
    v_bbits   int;
    v_bdata   bytea;
    nb        int;
    is_global boolean;
    dn        text[] := p_dn;
    cn        text[] := p_cn;
    nm        text;
    old       text;
    k         int;
    i         int;
    pos       int;
    ent       int;
    li        int;
    pp        int;
    vpl       int;
    msk       bigint;
    vals      int[];
    ids       int[];
    words     bigint[];
    lw        bigint;
    changed   int := 0;
    ev_idx    int[] := '{}';
    ev_old    text[] := '{}';
    ev_new    text[] := '{}';
    mn        text[] := '{}';   -- per-call memo of the name-derived flags: a section holds few distinct states, so each is analysed once, not once per edit
    ma        boolean[] := '{}';
    mf        boolean[] := '{}';
    j         int;
    a_new     boolean; f_new boolean; a_old boolean; f_old boolean;
    d_pos     int[];            -- per distinct name: the entry value it has in this section (palette position, or the global state id)
    d_air     boolean[];        -- per distinct name: is it air / does it hold a fluid
    d_fl      boolean[];
    pa        smallint[];       -- per palette entry, filled on first use: 1 = air, 2 = not air; pf: 1 = no fluid, 2 = fluid (0 = not computed yet)
    pf        smallint[];
    jn        int;
begin
    select s.block_count, s.fluid_count, s.palette, s.bits, s.data, s.biome_palette, s.biome_bits, s.biome_data
      into v_bc, v_fc, v_pal, v_bits, v_data, v_bpal, v_bbits, v_bdata
      from mc.chunk_section s where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy for update;
    sec_ok := found;
    if not sec_ok then
        v_bc := 0; v_fc := 0; v_pal := array['minecraft:air']; v_bits := 0; v_data := ''::bytea; v_bpal := array[p_default_biome]; v_bbits := 0; v_bdata := ''::bytea;
    end if;
    -- sql/950: a compressed value stays compressed in a PL/pgSQL variable and EVERY use of it decompresses it again; decompress once here, not once per edit / per word
    v_pal := array_cat(v_pal, '{}'::text[]); v_data := v_data || ''::bytea; v_bpal := array_cat(v_bpal, '{}'::text[]); v_bdata := v_bdata || ''::bytea;
    is_global := cardinality(v_pal) = 0;

    -- grow the palette with the names this batch introduces (in order of first use)
    if not is_global then
        foreach nm in array array(select cn[array_position(dn, n)] from unnest(p_names) n) loop
            if array_position(v_pal, nm) is null then v_pal := v_pal || nm; end if;
        end loop;
    end if;
    nb := case when is_global then 16 else mc.block_bits_for(cardinality(v_pal)) end;
    if v_bits = 0 and nb = 0 then return row(0, '{}'::int[], '{}'::text[], '{}'::text[])::mc.sec_edit_result; end if;     -- single value, every edit sets that same value

    if v_bits = 0 and nb > 0 then
        -- single value -> palette: every entry is palette index 0 (the old single value), so the packed data starts as zeros; no unpack/repack
        vpl := 64 / nb;
        v_data := decode(repeat('00', ((4096 + vpl - 1) / vpl) * 8), 'hex');
        v_bits := nb;
    end if;

    if nb = v_bits then
        -- once per distinct name (a section sees a handful), not once per edit
        d_air := array(select mc.is_air(x) from unnest(cn) with ordinality u(x, o) order by o);
        d_fl  := array(select mc.has_fluid(x) from unnest(cn) with ordinality u(x, o) order by o);
        d_pos := case when is_global then array(select (select b.state_id from ref.block_state b where b.name = x) from unnest(cn) with ordinality u(x, o) order by o)
                      else array(select array_position(v_pal, x) - 1 from unnest(cn) with ordinality u(x, o) order by o) end;
        if not is_global then pa := array_fill(0::smallint, array[cardinality(v_pal)]); pf := array_fill(0::smallint, array[cardinality(v_pal)]); end if;
    end if;

    if nb = v_bits and cardinality(p_idx) <= 48 then
        ---------------------------------------------------------------- few edits, same bit width: overwrite just the affected longs in place (never unpacked)
        vpl := 64 / v_bits;
        msk := (1::bigint << v_bits) - 1;
        for k in 1 .. cardinality(p_idx) loop
            i := p_idx[k];
            jn := array_position(dn, p_names[k]);
            nm := cn[jn];
            pos := d_pos[jn];
            li := (i / vpl) * 8;                                   -- byte offset of the long holding this entry
            pp := (i % vpl) * v_bits;
            lw := proto.i64_read(v_data, li);
            ent := ((lw >> pp) & msk)::int;
            if ent = pos then continue; end if;
            old := case when is_global then mc.state_name(ent) else v_pal[ent + 1] end;
            v_data := overlay(v_data placing int8send((lw & ~(msk << pp)) | (pos::bigint << pp)) from li + 1 for 8);
            if is_global then
                j := array_position(mn, old);
                if j is null then mn := mn || old; ma := ma || mc.is_air(old); mf := mf || mc.has_fluid(old); j := cardinality(mn); end if;
                a_old := ma[j]; f_old := mf[j];
            else
                if pa[ent + 1] = 0 then pa[ent + 1] := case when mc.is_air(old) then 1 else 2 end; pf[ent + 1] := case when mc.has_fluid(old) then 2 else 1 end; end if;
                a_old := pa[ent + 1] = 1; f_old := pf[ent + 1] = 2;
            end if;
            v_bc := v_bc + (case when d_air[jn] then 0 else 1 end) - (case when a_old then 0 else 1 end);
            v_fc := v_fc + (case when d_fl[jn] then 1 else 0 end) - (case when f_old then 1 else 0 end);
            changed := changed + 1;
            ev_idx[changed] := i; ev_old[changed] := old; ev_new[changed] := nm;
        end loop;
    elsif nb = v_bits then
        ---------------------------------------------------------------- many edits, same bit width: unpack the longs once, edit, write back
        vpl := 64 / v_bits;
        msk := (1::bigint << v_bits) - 1;
        words := array(select proto.i64_read(v_data, w * 8) from generate_series(0, (4096 + vpl - 1) / vpl - 1) w order by w);
        for k in 1 .. cardinality(p_idx) loop
            i := p_idx[k];
            jn := array_position(dn, p_names[k]);
            nm := cn[jn];
            pos := d_pos[jn];
            li := i / vpl + 1;
            pp := (i % vpl) * v_bits;
            ent := ((words[li] >> pp) & msk)::int;
            if ent = pos then continue; end if;
            old := case when is_global then mc.state_name(ent) else v_pal[ent + 1] end;
            words[li] := (words[li] & ~(msk << pp)) | (pos::bigint << pp);
            if is_global then
                j := array_position(mn, old);
                if j is null then mn := mn || old; ma := ma || mc.is_air(old); mf := mf || mc.has_fluid(old); j := cardinality(mn); end if;
                a_old := ma[j]; f_old := mf[j];
            else
                if pa[ent + 1] = 0 then pa[ent + 1] := case when mc.is_air(old) then 1 else 2 end; pf[ent + 1] := case when mc.has_fluid(old) then 2 else 1 end; end if;
                a_old := pa[ent + 1] = 1; f_old := pf[ent + 1] = 2;
            end if;
            v_bc := v_bc + (case when d_air[jn] then 0 else 1 end) - (case when a_old then 0 else 1 end);
            v_fc := v_fc + (case when d_fl[jn] then 1 else 0 end) - (case when f_old then 1 else 0 end);
            changed := changed + 1;
            ev_idx[changed] := i; ev_old[changed] := old; ev_new[changed] := nm;
        end loop;
        v_data := (select string_agg(int8send(w), ''::bytea order by o) from unnest(words) with ordinality t(w, o));
    else
        ---------------------------------------------------------------- the bit width changes (palette growth past a width, palette -> global): repack once
        vals := mc.unpack_longs(v_data, v_bits, 4096);
        if not is_global and nb = 16 then
            ids := mc.palette_ids(v_pal);                            -- palette index -> global state id (includes the names added above)
            vals := array(select ids[e + 1] from unnest(vals) with ordinality t(e, o) order by o);
        end if;
        for k in 1 .. cardinality(p_idx) loop
            i := p_idx[k];
            nm := cn[array_position(dn, p_names[k])];
            pos := case when is_global or nb = 16 then mc.state_id(nm) else array_position(v_pal, nm) - 1 end;
            ent := vals[i + 1];
            if ent = pos then continue; end if;
            old := case when is_global or nb = 16 then mc.state_name(ent) else v_pal[ent + 1] end;
            vals[i + 1] := pos;
            j := array_position(mn, nm);
            if j is null then mn := mn || nm; ma := ma || mc.is_air(nm); mf := mf || mc.has_fluid(nm); j := cardinality(mn); end if;
            a_new := ma[j]; f_new := mf[j];
            j := array_position(mn, old);
            if j is null then mn := mn || old; ma := ma || mc.is_air(old); mf := mf || mc.has_fluid(old); j := cardinality(mn); end if;
            a_old := ma[j]; f_old := mf[j];
            v_bc := v_bc + (case when a_new then 0 else 1 end) - (case when a_old then 0 else 1 end);
            v_fc := v_fc + (case when f_new then 1 else 0 end) - (case when f_old then 1 else 0 end);
            changed := changed + 1;
            ev_idx[changed] := i; ev_old[changed] := old; ev_new[changed] := nm;
        end loop;
        v_data := mc.pack_longs(vals, nb);
        v_bits := nb;
        if nb = 16 then v_pal := '{}'; end if;
    end if;

    if changed = 0 then return row(0, '{}'::int[], '{}'::text[], '{}'::text[])::mc.sec_edit_result; end if;
    if sec_ok then
        update mc.chunk_section s set block_count = v_bc, fluid_count = v_fc, palette = v_pal, bits = v_bits, data = v_data
         where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy;
    else
        insert into mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data)
        values (p_dim, p_cx, p_cz, p_sy, v_bc, v_fc, v_pal, v_bits, v_data, v_bpal, v_bbits, v_bdata)
        on conflict (dimension, cx, cz, sy) do update
           set block_count = excluded.block_count, fluid_count = excluded.fluid_count, palette = excluded.palette, bits = excluded.bits, data = excluded.data;
    end if;
    return row(changed, ev_idx, ev_old, ev_new)::mc.sec_edit_result;
end $$;

-- The workhorse: apply edits (section-relative indexes and block names, applied in order, the last one wins) to one section in a single read and write.
-- If the palette stays within its current bit width only the affected longs change (no repacking); otherwise the section is repacked once.
-- Returns the number of blocks that actually changed.
create or replace function mc.edit_section(p_dim text, p_cx int, p_sy int, p_cz int, p_idx int[], p_names text[], p_canonical boolean default false)
returns int language plpgsql volatile as $$
declare
    d         mc.dimension%rowtype;
    sec_ok    boolean;
    v_bc      int;
    v_fc      int;
    v_pal     text[];
    v_bits    int;
    v_data    bytea;
    v_bpal    text[];
    v_bbits   int;
    v_bdata   bytea;
    nb        int;
    is_global boolean;
    dn        text[];
    cn        text[];
    missing   text;
    nm        text;
    old       text;
    k         int;
    i         int;
    pos       int;
    ent       int;
    li        int;
    pp        int;
    vpl       int;
    msk       bigint;
    vals      int[];
    ids       int[];
    words     bigint[];
    lw        bigint;
    hmb       smallint[];
    hmn       smallint[];
    hws       smallint[];
    hdirty    boolean;
    chunk_ok  boolean;
    hm_changed boolean := false;
    col       int;
    val       int;
    h1        int; h2 int; h3 int;
    changed   int := 0;
    res       mc.sec_edit_result;
    ev_idx    int[] := '{}';
    ev_old    text[] := '{}';
    ev_new    text[] := '{}';
    -- per-call memo of the name-derived flags: a section holds few distinct states, so each is analysed once, not once per edit
    mn        text[] := '{}';   -- names seen
    ma        boolean[] := '{}'; -- is air
    mf        boolean[] := '{}'; -- has fluid
    hn        text[] := '{}';   -- names whose heightmap flags were computed
    hfl       boolean[] := '{}'; -- three flags per name: world_surface, motion_blocking, motion_blocking_no_leaves
    j         int;
    a_new     boolean; f_new boolean; a_old boolean; f_old boolean;
    ofl       boolean[]; nfl boolean[];
begin
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if p_sy < (d.min_y >> 4) or p_sy >= ((d.min_y + d.height) >> 4) then
        raise exception 'section % is outside dimension % (y % .. %)', p_sy, p_dim, d.min_y, d.min_y + d.height - 1;
    end if;

    -- canonical state names, resolved once per distinct name, in one statement (a bare block name means its default state; unknown names are an error)
    if p_canonical then
        select array_agg(n order by n) into dn from (select distinct n from unnest(p_names) n) q;
        cn := dn;
    else
        select array_agg(q.n order by q.n), array_agg(coalesce(s.name, ds.name) order by q.n), (array_agg(q.n order by q.n) filter (where coalesce(s.name, ds.name) is null))[1]
          into dn, cn, missing
          from (select distinct n from unnest(p_names) n) q
          left join ref.block_state s on s.name = q.n
          left join ref.block b on b.name = q.n
          left join ref.block_state ds on ds.state_id = b.default_state;
        if missing is not null then perform mc.canon_state(missing); end if;       -- raises 'unknown block state ...'
    end if;

    -- the chunk row (and its heightmaps) once; created if this is the first edit in the chunk
    select c.hm_motion_blocking, c.hm_motion_blocking_no_leaves, c.hm_world_surface, c.hm_dirty into hmb, hmn, hws, hdirty
      from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    chunk_ok := found;
    -- sql/950: the heightmaps of a chunk row are stored compressed; a compressed value stays compressed in a variable and every subscript decompresses it again: once here
    hws := case when hws is null then null else array_cat(hws, '{}'::smallint[]) end; hmb := case when hmb is null then null else array_cat(hmb, '{}'::smallint[]) end; hmn := case when hmn is null then null else array_cat(hmn, '{}'::smallint[]) end;
    if not chunk_ok then insert into mc.chunk (dimension, cx, cz) values (p_dim, p_cx, p_cz) on conflict do nothing; end if;

    res := mc.edit_section_core(p_dim, p_cx, p_sy, p_cz, p_idx, p_names, dn, cn, d.default_biome);
    changed := res.changed;
    if changed = 0 then return 0; end if;
    ev_idx := res.ev_idx; ev_old := res.ev_old; ev_new := res.ev_new;

    -- Heightmaps are kept exact incrementally (a chunk flagged hm_dirty or without heightmaps is recomputed in full by mc.ensure_chunk_current).
    -- An edit below the top of every column kind it could affect changes nothing (a block placed or removed under the surface), so its flags are not even looked at.
    if hws is not null and not hdirty then
        for k in 1 .. changed loop
            i := ev_idx[k];
            col := (i & 15) + 16 * ((i >> 4) & 15);
            val := p_sy * 16 + (i >> 8) + 1 - d.min_y;
            h1 := hws[col + 1]; h2 := hmb[col + 1]; h3 := hmn[col + 1];
            continue when val < least(h1, h2, h3);
            j := array_position(hn, ev_old[k]);
            if j is null then hn := hn || ev_old[k]; hfl := hfl || mc.heightmap_flags(ev_old[k]); j := cardinality(hn); end if;
            ofl := hfl[(j - 1) * 3 + 1 : (j - 1) * 3 + 3];
            j := array_position(hn, ev_new[k]);
            if j is null then hn := hn || ev_new[k]; hfl := hfl || mc.heightmap_flags(ev_new[k]); j := cardinality(hn); end if;
            nfl := hfl[(j - 1) * 3 + 1 : (j - 1) * 3 + 3];
            hws[col + 1] := mc.hm_step(h1::smallint, val, ofl[1], nfl[1], p_dim, p_cx, p_cz, col, 1, d.min_y);
            hmb[col + 1] := mc.hm_step(h2::smallint, val, ofl[2], nfl[2], p_dim, p_cx, p_cz, col, 2, d.min_y);
            hmn[col + 1] := mc.hm_step(h3::smallint, val, ofl[3], nfl[3], p_dim, p_cx, p_cz, col, 3, d.min_y);
            if hws[col + 1] <> h1 or hmb[col + 1] <> h2 or hmn[col + 1] <> h3 then hm_changed := true; end if;
        end loop;
    end if;
    if hm_changed then
        update mc.chunk c set version = c.version + 1, dirty = true,
                              hm_world_surface = hws, hm_motion_blocking = hmb, hm_motion_blocking_no_leaves = hmn
         where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    else
        update mc.chunk c set version = c.version + 1, dirty = true where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    end if;
    insert into mc.block_event (dimension, x, y, z, old_state, new_state)
    select p_dim, p_cx * 16 + (e.i & 15), p_sy * 16 + (e.i >> 8), p_cz * 16 + ((e.i >> 4) & 15), e.o, e.n
      from unnest(ev_idx, ev_old, ev_new) e(i, o, n);
    return changed;
end $$;

-- One edit, the common case: the section exists, it is a palette section (not single-value, not global) and the palette either already holds the block or
-- can take it without changing the bit width.  That path touches the database five times (section read + lock, section write, chunk bump with the one
-- column's heightmap values, the event row) instead of the general function's dozen, and skips every lookup it can.  Anything else (a new section, a bit
-- width change, a bare block name, an unknown name) goes to mc.edit_section, which handles it and raises the errors.
create or replace function mc.set_block(p_dim text, x int, y int, z int, p_block text) returns boolean language plpgsql volatile as $$
declare
    qx    int := x >> 4;
    qz    int := z >> 4;
    qs    int := y >> 4;
    i     int := ((y & 15) << 8) | ((z & 15) << 4) | (x & 15);
    v_pal text[]; v_bits int; v_data bytea; v_bc int; v_fc int;
    nm    text := p_block;
    pos   int;
    vpl   int; msk bigint; li int; pp int; lw bigint; ent int;
    old   text;
    min_y int; hdirty boolean; h1 int; h2 int; h3 int;
    col   int := (x & 15) + 16 * (z & 15);
    val   int;
    ofl   boolean[]; nfl boolean[];
    n1    int; n2 int; n3 int;
begin
    select s.palette, s.bits, s.data, s.block_count, s.fluid_count into v_pal, v_bits, v_data, v_bc, v_fc
      from mc.chunk_section s where s.dimension = p_dim and s.cx = qx and s.cz = qz and s.sy = qs for no key update;
    if not found or v_bits = 0 or cardinality(v_pal) = 0 then
        return mc.edit_section(p_dim, qx, qs, qz, array[i], array[p_block]) > 0;
    end if;
    pos := array_position(v_pal, nm);                         -- palette entries are canonical state names: a hit needs no lookup
    if pos is null then
        select s.name into nm from ref.block_state s where s.name = p_block;
        if nm is null then return mc.edit_section(p_dim, qx, qs, qz, array[i], array[p_block]) > 0; end if;     -- bare name or unknown
        if mc.block_bits_for(cardinality(v_pal) + 1) <> v_bits then return mc.edit_section(p_dim, qx, qs, qz, array[i], array[p_block]) > 0; end if;
        v_pal := v_pal || nm;
        pos := cardinality(v_pal);
    end if;
    pos := pos - 1;                                           -- the entry value

    vpl := 64 / v_bits;
    msk := (1::bigint << v_bits) - 1;
    li  := (i / vpl) * 8;
    pp  := (i % vpl) * v_bits;
    lw  := proto.i64_read(v_data, li);
    ent := ((lw >> pp) & msk)::int;
    if ent = pos then return false; end if;                   -- already that block
    old := v_pal[ent + 1];
    v_data := overlay(v_data placing int8send((lw & ~(msk << pp)) | (pos::bigint << pp)) from li + 1 for 8);
    v_bc := v_bc + (case when mc.is_air(nm) then 0 else 1 end) - (case when mc.is_air(old) then 0 else 1 end);
    v_fc := v_fc + (case when mc.has_fluid(nm) then 1 else 0 end) - (case when mc.has_fluid(old) then 1 else 0 end);
    update mc.chunk_section s set block_count = v_bc, fluid_count = v_fc, palette = v_pal, data = v_data
     where s.dimension = p_dim and s.cx = qx and s.cz = qz and s.sy = qs;

    -- bump the chunk (version, dirty) and read the three heightmap values of this column in the same statement
    update mc.chunk c set version = c.version + 1, dirty = true
      from mc.dimension d
     where c.dimension = p_dim and c.cx = qx and c.cz = qz and d.name = c.dimension
    returning d.min_y, c.hm_dirty, c.hm_world_surface[col + 1], c.hm_motion_blocking[col + 1], c.hm_motion_blocking_no_leaves[col + 1]
         into min_y, hdirty, h1, h2, h3;
    -- heightmaps stay exact incrementally; an edit below the top of every kind cannot change them (see mc.edit_section)
    if h1 is not null and not hdirty then
        val := qs * 16 + (i >> 8) + 1 - min_y;
        if val >= least(h1, h2, h3) then
            ofl := mc.heightmap_flags(old);
            nfl := mc.heightmap_flags(nm);
            n1 := mc.hm_step(h1::smallint, val, ofl[1], nfl[1], p_dim, qx, qz, col, 1, min_y);
            n2 := mc.hm_step(h2::smallint, val, ofl[2], nfl[2], p_dim, qx, qz, col, 2, min_y);
            n3 := mc.hm_step(h3::smallint, val, ofl[3], nfl[3], p_dim, qx, qz, col, 3, min_y);
            if n1 <> h1 or n2 <> h2 or n3 <> h3 then
                update mc.chunk c set hm_world_surface[col + 1] = n1, hm_motion_blocking[col + 1] = n2, hm_motion_blocking_no_leaves[col + 1] = n3
                 where c.dimension = p_dim and c.cx = qx and c.cz = qz;
            end if;
        end if;
    end if;
    insert into mc.block_event (dimension, x, y, z, old_state, new_state) values (p_dim, x, y, z, old, nm);
    return true;
end $$;

-- mc.set_blocks (many edits at once) is defined in sql/290_world_batch.sql: one set-based pass over all touched sections.

-- All 4,096 positions of a section as a 'cells' bit map.
create or replace function mc.block_event_full_cells() returns bytea language sql immutable parallel safe as $$ select decode(repeat('ff', 512), 'hex') $$;

-- The positions of a box inside one section as a bit map: bit (y << 8 | z << 4 | x), bit i is bit i % 8 of byte i / 8, 512 bytes (the 'cells' of a block event).
-- Built from text: a row of 16 x positions is 4 hex digits, a slab of 16 rows (one y) 64, the section 1,024.
create or replace function mc.box_bitmap(a_x int, b_x int, a_y int, b_y int, a_z int, b_z int) returns bytea language plpgsql immutable parallel safe as $$
declare
    m    int := ((1 << (b_x + 1)) - 1) & ~((1 << a_x) - 1);                       -- the x range as 16 bits
    rw   text := lpad(to_hex(m & 255), 2, '0') || lpad(to_hex(m >> 8), 2, '0');   -- byte 0 = x 0..7, byte 1 = x 8..15
    slab text := repeat('0000', a_z) || repeat(rw, b_z - a_z + 1) || repeat('0000', 15 - b_z);
    zero text := repeat('0', 64);
begin
    return decode(repeat(zero, a_y) || repeat(slab, b_y - a_y + 1) || repeat(zero, 15 - b_y), 'hex');
end $$;

-- Fill a box that lies inside ONE section.  Returns the number of positions that changed, or -1 when it did not handle the section (global palette: the caller falls back to
-- mc.edit_section).  It touches neither the chunk row nor the heightmaps (mc.fill does, once per chunk); it writes the section and ONE event of kind 'cells' with the
-- changed positions as a bit map (docs/WORLD.md "Block change packets"), instead of one event row per block.
--   * A single-value section that gets another block becomes the palette [old, new] with the box fields set (no unpack); a whole section becomes a single-value section.
--   * A palette section is edited word by word: for each row of the box (one y and z, the x range) the masks of the entries inside the box are built from table lookups,
--     the entries equal to the new block, to an air state and to a fluid state are counted with a SWAR zero-field test (no unpacking), and the new word is
--     (old and not mask) or (new value and mask).  A palette that outgrows its bit width is repacked once.
-- The results (palette, bits, packed data, block and fluid counts) are those of mc.edit_section for the same blocks, except for a whole section (single value).
create or replace function mc.fill_section(p_dim text, p_cx int, p_sy int, p_cz int, a_x int, b_x int, a_y int, b_y int, a_z int, b_z int, p_nm text, p_default_biome text)
returns int language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    v_bc int; v_fc int; v_pal text[]; v_bits int; v_data bytea; sec_ok boolean;
    v_bpal text[]; v_bbits int; v_bdata bytea;
    nbox     int := (b_x - a_x + 1) * (b_y - a_y + 1) * (b_z - a_z + 1);
    whole    boolean := (b_x - a_x + 1) * (b_y - a_y + 1) * (b_z - a_z + 1) = 4096;
    nm_air  boolean := mc.is_air(p_nm);
    nm_fl   boolean := mc.has_fluid(p_nm);
    n_old   int;                              -- palette entries before the new block was appended
    newpos  int;                              -- palette position (1-based) of the new block
    nv      bigint;                           -- its entry value
    nb      int;
    counting boolean := true;                 -- false when the old content is known (a single-value section): then nothing is counted
    b       int;  vpl int;  nw int;  msk bigint;
    words   bigint[]; ow bigint[];
    ou      bigint[]; fm bigint[];            -- ou[j + 1]: bit 0 of the first j fields; fm[j + 1]: all bits of the first j fields
    shs     int[] := '{}';                    -- the shift schedule of the zero-field test
    cov     int;  sh int;
    ones    bigint;                           -- bit 0 of every field
    trep    bigint[] := '{}';                 -- per tracked value: that value in every field.  [1] the new block, then the old air entries, then the old fluid entries
    tc      bigint[] := '{}';                 -- ... and how many fields inside the box equal it
    n_air   int := 0;  n_fl int := 0;  nt int := 0;
    y int; z int; i0 int; i1 int; w int; ws int; lo int; hi int; mo bigint; mk bigint; old bigint; yv bigint; f bigint; t int; k int; s int; e int;
    changed int; old_air bigint := 0; old_fl bigint := 0;
    bm      bytea;
    xx int; idx int;
    rep     bigint;
begin
    select s.block_count, s.fluid_count, s.palette, s.bits, s.data, s.biome_palette, s.biome_bits, s.biome_data
      into v_bc, v_fc, v_pal, v_bits, v_data, v_bpal, v_bbits, v_bdata
      from mc.chunk_section s where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy for update;
    sec_ok := found;
    if not sec_ok then
        v_bc := 0; v_fc := 0; v_pal := array['minecraft:air']; v_bits := 0; v_data := ''::bytea; v_bpal := array[p_default_biome]; v_bbits := 0; v_bdata := ''::bytea;
    end if;
    -- sql/950: a compressed value stays compressed in a PL/pgSQL variable and EVERY use of it decompresses it again; decompress once here, not once per edit / per word
    v_pal := array_cat(v_pal, '{}'::text[]); v_data := v_data || ''::bytea; v_bpal := array_cat(v_bpal, '{}'::text[]); v_bdata := v_bdata || ''::bytea;
    if cardinality(v_pal) = 0 or (v_bits = 0 and cardinality(v_pal) <> 1) then return -1; end if;      -- global palette (or an unexpected single-value layout): the general path
    n_old := cardinality(v_pal);
    newpos := array_position(v_pal, p_nm);

    if v_bits = 0 then
        if newpos is not null then return 0; end if;                       -- the section already is that block everywhere
        changed := nbox;
        old_air := case when mc.is_air(v_pal[1]) then nbox else 0 end;      -- everything inside the box is the old single value
        old_fl  := case when mc.has_fluid(v_pal[1]) then nbox else 0 end;
        if whole then
            v_bc := case when nm_air then 0 else 4096 end; v_fc := case when nm_fl then 4096 else 0 end;
            v_pal := array[p_nm]; v_data := ''::bytea;                      -- a single-value section again (v_bits stays 0)
            bm := mc.block_event_full_cells();
        else
            v_pal := v_pal || p_nm; newpos := 2; v_bits := 4; v_data := null;
            counting := false;
            bm := mc.box_bitmap(a_x, b_x, a_y, b_y, a_z, b_z);
        end if;
    else
        if newpos is null then
            v_pal := v_pal || p_nm; newpos := cardinality(v_pal); nb := mc.block_bits_for(newpos);
            if nb = 16 then return -1; end if;                              -- the palette outgrows 8 bits: the global palette, the general path
            if nb > v_bits then v_data := mc.pack_longs(mc.unpack_longs(v_data, v_bits, 4096), nb); v_bits := nb; end if;
        end if;
    end if;
    nv := newpos - 1;

    if not (v_bits = 0 and whole) then
        ---------------------------------------------------------------- set the box fields word by word; count (SWAR) unless the old content is known
        b := v_bits; vpl := 64 / b; nw := (4096 + vpl - 1) / vpl; msk := (1::bigint << b) - 1;
        ou := array_fill(0::bigint, array[vpl + 1]); fm := array_fill(0::bigint, array[vpl + 1]);
        rep := 0;
        for k in 0 .. vpl - 1 loop
            ou[k + 2] := ou[k + 1] | (1::bigint << (k * b));
            fm[k + 2] := fm[k + 1] | (msk << (k * b));
            rep := rep | (nv << (k * b));
        end loop;
        ones := ou[vpl + 1];
        if counting then
            cov := 1;
            while cov < b loop sh := least(cov, b - cov); shs := shs || sh; cov := cov + sh; end loop;
            -- the values to count: the new block (it tells how many positions change) and, unless the whole section is replaced (the new counts are then known), the entries
            -- of the old palette that are air or hold a fluid (the block and fluid counts)
            trep := array[rep]; tc := array[0::bigint]; nt := 1;
            if not whole then
                for e in 0 .. n_old - 1 loop
                    if mc.is_air(v_pal[e + 1]) then
                        rep := 0; for k in 0 .. vpl - 1 loop rep := rep | (e::bigint << (k * b)); end loop;
                        trep := trep || rep; tc := tc || 0::bigint; nt := nt + 1; n_air := n_air + 1;
                    end if;
                end loop;
                for e in 0 .. n_old - 1 loop
                    if mc.has_fluid(v_pal[e + 1]) then
                        rep := 0; for k in 0 .. vpl - 1 loop rep := rep | (e::bigint << (k * b)); end loop;
                        trep := trep || rep; tc := tc || 0::bigint; nt := nt + 1; n_fl := n_fl + 1;
                    end if;
                end loop;
            end if;
            words := array(select proto.i64_read(v_data, w2 * 8) from generate_series(0, nw - 1) w2 order by w2);
            ow := words;
        else
            words := array_fill(0::bigint, array[nw]);
        end if;
        rep := trep[1];
        if not counting then
            rep := 0; for k in 0 .. vpl - 1 loop rep := rep | (nv << (k * b)); end loop;
        end if;

        for y in a_y .. b_y loop
            for z in a_z .. b_z loop
                i0 := (y << 8) | (z << 4) | a_x;
                i1 := i0 + (b_x - a_x);
                w := i0 / vpl;
                loop
                    ws := w * vpl;
                    lo := greatest(i0, ws) - ws;
                    hi := least(i1, ws + vpl - 1) - ws;
                    mo := ou[hi + 2] & ~ou[lo + 1];                        -- bit 0 of the fields inside the box
                    mk := fm[hi + 2] & ~fm[lo + 1];                        -- all bits of them
                    old := words[w + 1];
                    if counting then
                        for t in 1 .. nt loop
                            yv := old # trep[t];                           -- zero field = equal to the counted value
                            f := yv;
                            foreach sh in array shs loop f := f | (f >> sh); end loop;
                            tc[t] := tc[t] + bit_count(int8send(((f & ones) # ones) & mo));
                        end loop;
                    end if;
                    words[w + 1] := (old & ~mk) | (rep & mk);
                    exit when ws + vpl > i1;
                    w := w + 1;
                end loop;
            end loop;
        end loop;

        if counting then
            changed := nbox - tc[1]::int;
            for t in 2 .. 1 + n_air loop old_air := old_air + tc[t]; end loop;
            for t in 2 + n_air .. 1 + n_air + n_fl loop old_fl := old_fl + tc[t]; end loop;
            if changed = 0 then return 0; end if;                           -- nothing differs: nothing is written, no event
            if tc[1] = 0 then
                bm := case when whole then mc.block_event_full_cells() else mc.box_bitmap(a_x, b_x, a_y, b_y, a_z, b_z) end;
            else
                -- only some positions of the box differed: read them off the old words
                bm := decode(repeat('00', 512), 'hex');
                for y in a_y .. b_y loop
                    for z in a_z .. b_z loop
                        for xx in a_x .. b_x loop
                            idx := (y << 8) | (z << 4) | xx;
                            if ((ow[idx / vpl + 1] >> ((idx % vpl) * b)) & msk) <> nv then
                                bm := set_byte(bm, idx >> 3, get_byte(bm, idx >> 3) | (1 << (idx & 7)));
                            end if;
                        end loop;
                    end loop;
                end loop;
            end if;
            if whole then
                v_bc := case when nm_air then 0 else 4096 end; v_fc := case when nm_fl then 4096 else 0 end;
                v_pal := array[p_nm]; v_bits := 0; v_data := ''::bytea;
            else
                v_bc := v_bc - (nbox - old_air::int) + (case when nm_air then 0 else nbox end);
                v_fc := v_fc - old_fl::int + (case when nm_fl then nbox else 0 end);
            end if;
        else
            -- (a single-value section that became a palette section: the counts follow from the old value)
            v_bc := v_bc - (nbox - old_air::int) + (case when nm_air then 0 else nbox end);
            v_fc := v_fc - old_fl::int + (case when nm_fl then nbox else 0 end);
        end if;
        if v_bits > 0 then
            v_data := (select string_agg(int8send(x), ''::bytea order by o) from unnest(words) with ordinality t2(x, o));
        end if;
    end if;

    if sec_ok then
        update mc.chunk_section s set block_count = v_bc, fluid_count = v_fc, palette = v_pal, bits = v_bits, data = v_data
         where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy;
    else
        insert into mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data)
        values (p_dim, p_cx, p_cz, p_sy, v_bc, v_fc, v_pal, v_bits, v_data, v_bpal, v_bbits, v_bdata)
        on conflict (dimension, cx, cz, sy) do update
           set block_count = excluded.block_count, fluid_count = excluded.fluid_count, palette = excluded.palette, bits = excluded.bits, data = excluded.data;
    end if;
    insert into mc.block_event (kind, dimension, x, y, z, old_state, new_state, cells) values ('cells', p_dim, p_cx * 16, p_sy * 16, p_cz * 16, '*', p_nm, bm);
    return changed;
end $$;

-- A fill: a box (inclusive corners).  Per section the box covers, mc.fill_section does the work; a box of at most 48 blocks in a section goes through mc.edit_section instead
-- (per-block events, heightmaps kept exact incrementally: for a handful of blocks that is both cheaper and keeps the chunk's heightmaps valid).  Everything else flags
-- the chunk's heightmaps for a full recompute at the next send (hm_dirty), as whole-section fills always did.  Returns the number of blocks covered.
create or replace function mc.fill(p_dim text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, p_block text) returns int language plpgsql volatile as $$
declare
    d       mc.dimension%rowtype;
    nm      text := mc.canon_state(p_block);
    lo_x    int := least(x1, x2);  hi_x int := greatest(x1, x2);
    lo_y    int := least(y1, y2);  hi_y int := greatest(y1, y2);
    lo_z    int := least(z1, z2);  hi_z int := greatest(z1, z2);
    v_cx    int; v_cz int; v_sy int;
    a_x     int; b_x int; a_y int; b_y int; a_z int; b_z int;
    idxs    int[];
    covered int := 0;
    n_box   int;
    r       int;
    secs    int;                                   -- sections of the current chunk written by mc.fill_section
begin
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if lo_y < d.min_y or hi_y >= d.min_y + d.height then raise exception 'fill is outside dimension % (y % .. %)', p_dim, d.min_y, d.min_y + d.height - 1; end if;
    insert into mc.chunk (dimension, cx, cz)
    select p_dim, cx, cz from generate_series(lo_x >> 4, hi_x >> 4) cx, generate_series(lo_z >> 4, hi_z >> 4) cz on conflict do nothing;
    for v_cx in (lo_x >> 4) .. (hi_x >> 4) loop
      for v_cz in (lo_z >> 4) .. (hi_z >> 4) loop
        secs := 0;
        for v_sy in (lo_y >> 4) .. (hi_y >> 4) loop
            a_x := greatest(lo_x, v_cx * 16); b_x := least(hi_x, v_cx * 16 + 15);
            a_y := greatest(lo_y, v_sy * 16); b_y := least(hi_y, v_sy * 16 + 15);
            a_z := greatest(lo_z, v_cz * 16); b_z := least(hi_z, v_cz * 16 + 15);
            n_box := (b_x - a_x + 1) * (b_y - a_y + 1) * (b_z - a_z + 1);
            covered := covered + n_box;
            r := -1;
            if n_box > 48 then
                r := mc.fill_section(p_dim, v_cx, v_sy, v_cz, a_x & 15, b_x & 15, a_y & 15, b_y & 15, a_z & 15, b_z & 15, nm, d.default_biome);
                if r > 0 then secs := secs + 1; end if;
            end if;
            if r = -1 then
                idxs := array(select mc.section_idx(x, y, z) from generate_series(a_x, b_x) x, generate_series(a_y, b_y) y, generate_series(a_z, b_z) z order by z, y, x);      -- /fill's order: x fastest, then y, then z
                perform mc.edit_section(p_dim, v_cx, v_sy, v_cz, idxs, array_fill(nm, array[cardinality(idxs)]), true);
            end if;
        end loop;
        if secs > 0 then
            update mc.chunk c set version = c.version + secs, dirty = true, hm_dirty = true where c.dimension = p_dim and c.cx = v_cx and c.cz = v_cz;
        end if;
      end loop;
    end loop;
    return covered;
end $$;

------------------------------------------------------------------------------------------------ readable view
-- The non-air blocks of one stored section as rows.  Palette sections test "is air" once per palette entry, not once per block.
create or replace function mc.section_blocks(s mc.chunk_section, include_air boolean default false)
returns table (x int, y int, z int, block text) language sql stable as $$
  -- MATERIALIZED: the per-palette-entry air flags are computed once, not re-evaluated for each of the 4096 blocks
  with a as materialized (select array(select mc.is_air(p) from unnest(s.palette) with ordinality q(p, o) order by o) as air)
  select s.cx * 16 + (u.i & 15), s.sy * 16 + (u.i >> 8), s.cz * 16 + ((u.i >> 4) & 15),
         case when cardinality(s.palette) = 0 then mc.state_name(u.e) else s.palette[u.e + 1] end
  from a, lateral (select o - 1 as i, e from unnest(mc.unpack_longs(s.data, s.bits, 4096)) with ordinality t(e, o)) u
  where include_air
     or not (case when cardinality(s.palette) = 0 then mc.is_air(mc.state_name(u.e)) else a.air[u.e + 1] end) $$;

-- Every non-air block of every stored section.  An unrestricted scan: Postgres cannot turn "WHERE x = 5" into a section lookup, because x is computed
-- from the section and the index inside it.  Use mc.blocks_in / mc.block_at for anything but small worlds (see docs/WORLD.md for measurements).
create or replace view mc.blocks as
  select s.dimension, b.x, b.y, b.z, b.block
  from mc.chunk_section s cross join lateral mc.section_blocks(s) b
  where s.block_count > 0;                    -- sections without a non-air block are skipped before unpacking

create or replace function mc.blocks_in(p_dim text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, include_air boolean default false)
returns table (dimension text, x int, y int, z int, block text) language sql stable as $$
  select s.dimension, b.x, b.y, b.z, b.block
  from mc.chunk_section s cross join lateral mc.section_blocks(s, include_air) b
  where s.dimension = p_dim
    and (include_air or s.block_count > 0)
    and s.cx between least(x1, x2) >> 4 and greatest(x1, x2) >> 4
    and s.cz between least(z1, z2) >> 4 and greatest(z1, z2) >> 4
    and s.sy between least(y1, y2) >> 4 and greatest(y1, y2) >> 4
    and b.x between least(x1, x2) and greatest(x1, x2)
    and b.y between least(y1, y2) and greatest(y1, y2)
    and b.z between least(z1, z2) and greatest(z1, z2) $$;

create or replace function mc.block_at(p_dim text, x int, y int, z int) returns table (dimension text, x int, y int, z int, block text) language sql stable as $$
  select p_dim, x, y, z, mc.get_block(p_dim, x, y, z) where mc.get_block(p_dim, x, y, z) is not null $$;

create or replace function mc.blocks_dml() returns trigger language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        perform mc.set_block(new.dimension, new.x, new.y, new.z, new.block);
        return new;
    elsif tg_op = 'UPDATE' then
        if (old.dimension, old.x, old.y, old.z) is distinct from (new.dimension, new.x, new.y, new.z) then
            perform mc.set_block(old.dimension, old.x, old.y, old.z, 'minecraft:air');     -- the block moved
        end if;
        perform mc.set_block(new.dimension, new.x, new.y, new.z, new.block);
        return new;
    else
        perform mc.set_block(old.dimension, old.x, old.y, old.z, 'minecraft:air');
        return old;
    end if;
end $$;

drop trigger if exists blocks_dml on mc.blocks;
create trigger blocks_dml instead of insert or update or delete on mc.blocks for each row execute function mc.blocks_dml();

------------------------------------------------------------------------------------------------ maintenance
-- Rebuild a section with a minimal palette: unused entries dropped, remaining ones in order of first appearance by block index (bottom-up, like the
-- generators), single-value when uniform; an all-air section is deleted.  Edits never shrink a palette (vanilla's in-memory sections do not either),
-- so this reclaims space after heavy editing.  Bumps the chunk version because the packet bytes change.  Returns false when nothing was stored.
create or replace function mc.compact_section(p_dim text, p_cx int, p_sy int, p_cz int) returns boolean language plpgsql volatile as $$
declare
    sec   mc.chunk_section%rowtype;
    names text[];
    pal   text[];
    idxs  int[];
    nb    int;
    nonair int;
    fluids int;
begin
    select * into sec from mc.chunk_section s where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy for update;
    if not found then return false; end if;
    -- sql/950: a compressed value stays compressed in a PL/pgSQL variable and EVERY use of it decompresses it again; decompress once here, not once per edit / per word
    sec.palette := array_cat(sec.palette, '{}'::text[]); sec.data := sec.data || ''::bytea;
    -- state name of every block, in index order
    names := array(select case when cardinality(sec.palette) = 0 then mc.state_name(u.e) else sec.palette[u.e + 1] end
                   from unnest(mc.unpack_longs(sec.data, sec.bits, 4096)) with ordinality u(e, o) order by u.o);
    select count(*) filter (where not mc.is_air(n)), count(*) filter (where mc.has_fluid(n)) into nonair, fluids from unnest(names) n;
    if nonair = 0 then
        delete from mc.chunk_section s where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy;
    else
        pal := array(select n from (select n, min(o) as first from unnest(names) with ordinality t(n, o) group by n) q order by first);
        nb := mc.block_bits_for(cardinality(pal));
        if nb = 16 then
            update mc.chunk_section s set block_count = nonair, fluid_count = fluids, palette = '{}', bits = 16,
                   data = mc.pack_longs(array(select mc.state_id(n) from unnest(names) with ordinality t(n, o) order by o), 16)
             where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy;
        else
            idxs := array(select array_position(pal, n) - 1 from unnest(names) with ordinality t(n, o) order by o);
            update mc.chunk_section s set block_count = nonair, fluid_count = fluids, palette = pal, bits = nb,
                   data = case when nb = 0 then '\x'::bytea else mc.pack_longs(idxs, nb) end
             where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy;
        end if;
    end if;
    update mc.chunk c set version = c.version + 1, dirty = true where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    return true;
end $$;
