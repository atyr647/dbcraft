-- Reading and editing blocks.
--
--   mc.get_block(dim, x, y, z)                         one block; NULL when the chunk does not exist, 'minecraft:air' for a missing section
--   mc.set_block(dim, x, y, z, block)                  one edit; true when the block changed
--   mc.set_blocks(dim, xs[], ys[], zs[], blocks[])     many edits, grouped by section (one write per touched section); returns blocks changed
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

-- The workhorse: apply edits (section-relative indexes and block names, applied in order, the last one wins) to one section in a single read and write.
-- If the palette stays within its current bit width only the affected longs change (no repacking); otherwise the section is repacked once.
-- Returns the number of blocks that actually changed.
create or replace function mc.edit_section(p_dim text, p_cx int, p_sy int, p_cz int, p_idx int[], p_names text[], p_canonical boolean default false)
returns int language plpgsql volatile as $$
declare
    d        mc.dimension%rowtype;
    sec      mc.chunk_section%rowtype;
    pal      text[];
    bits     int;
    nb       int;
    data     bytea;
    is_global boolean;
    dn       text[];
    cn       text[];
    nm       text;
    old      text;
    k        int;
    i        int;
    pos      int;
    ent      int;
    li       int;
    pp       int;
    vpl      int;
    msk      bigint;
    vals     int[];
    ids      int[];
    words    bigint[];
    bc       int;
    fc       int;
    changed  int := 0;
    ev_idx   int[] := '{}';
    ev_old   text[] := '{}';
    ev_new   text[] := '{}';
begin
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if p_sy < (d.min_y >> 4) or p_sy >= ((d.min_y + d.height) >> 4) then
        raise exception 'section % is outside dimension % (y % .. %)', p_sy, p_dim, d.min_y, d.min_y + d.height - 1;
    end if;

    -- canonical state names, resolved once per distinct name
    if p_canonical then
        dn := array(select n from unnest(p_names) n group by n order by n);
        cn := dn;
    else
        select array_agg(n order by n), array_agg(mc.canon_state(n) order by n) into dn, cn from (select distinct n from unnest(p_names) n) q;
    end if;

    insert into mc.chunk (dimension, cx, cz) values (p_dim, p_cx, p_cz) on conflict do nothing;
    select * into sec from mc.chunk_section s where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy for update;
    if not found then
        sec := (p_dim, p_cx, p_cz, p_sy, 0, 0, array['minecraft:air'], 0, ''::bytea, array[d.default_biome], 0, ''::bytea)::mc.chunk_section;
    end if;
    pal := sec.palette; bits := sec.bits; data := sec.data; bc := sec.block_count; fc := sec.fluid_count;
    is_global := cardinality(pal) = 0;

    -- grow the palette with the names this batch introduces (in order of first use)
    if not is_global then
        foreach nm in array array(select cn[array_position(dn, n)] from unnest(p_names) n) loop
            if array_position(pal, nm) is null then pal := pal || nm; end if;
        end loop;
    end if;
    nb := case when is_global then 16 else mc.block_bits_for(cardinality(pal)) end;
    if bits = 0 and nb = 0 then return 0; end if;     -- single value, every edit sets that same value

    if nb = bits then
        ---------------------------------------------------------------- fast path: same bit width, rewrite only the touched longs
        vpl := 64 / bits;
        msk := (1::bigint << bits) - 1;
        words := array(select proto.i64_read(data, w * 8) from generate_series(0, (4096 + vpl - 1) / vpl - 1) w order by w);
        for k in 1 .. cardinality(p_idx) loop
            i := p_idx[k];
            nm := cn[array_position(dn, p_names[k])];
            pos := case when is_global then mc.state_id(nm) else array_position(pal, nm) - 1 end;
            li := i / vpl + 1;
            pp := (i % vpl) * bits;
            ent := ((words[li] >> pp) & msk)::int;
            if ent = pos then continue; end if;
            old := case when is_global then mc.state_name(ent) else pal[ent + 1] end;
            words[li] := (words[li] & ~(msk << pp)) | (pos::bigint << pp);
            bc := bc + (case when mc.is_air(nm) then 0 else 1 end) - (case when mc.is_air(old) then 0 else 1 end);
            fc := fc + (case when mc.has_fluid(nm) then 1 else 0 end) - (case when mc.has_fluid(old) then 1 else 0 end);
            changed := changed + 1;
            ev_idx := ev_idx || i; ev_old := ev_old || old; ev_new := ev_new || nm;
        end loop;
        data := (select string_agg(int8send(w), ''::bytea order by o) from unnest(words) with ordinality t(w, o));
    else
        ---------------------------------------------------------------- slow path: the bit width changes (single -> palette, palette growth, palette -> global): repack once
        vals := mc.unpack_longs(data, bits, 4096);                   -- bits = 0 yields zeros, i.e. palette index 0 everywhere
        if not is_global and nb = 16 then
            ids := mc.palette_ids(pal);                              -- palette index -> global state id (includes the names added above)
            vals := array(select ids[e + 1] from unnest(vals) with ordinality t(e, o) order by o);
        end if;
        for k in 1 .. cardinality(p_idx) loop
            i := p_idx[k];
            nm := cn[array_position(dn, p_names[k])];
            pos := case when is_global or nb = 16 then mc.state_id(nm) else array_position(pal, nm) - 1 end;
            ent := vals[i + 1];
            if ent = pos then continue; end if;
            old := case when is_global or nb = 16 then mc.state_name(ent) else pal[ent + 1] end;
            vals[i + 1] := pos;
            bc := bc + (case when mc.is_air(nm) then 0 else 1 end) - (case when mc.is_air(old) then 0 else 1 end);
            fc := fc + (case when mc.has_fluid(nm) then 1 else 0 end) - (case when mc.has_fluid(old) then 1 else 0 end);
            changed := changed + 1;
            ev_idx := ev_idx || i; ev_old := ev_old || old; ev_new := ev_new || nm;
        end loop;
        data := mc.pack_longs(vals, nb);
        bits := nb;
        if nb = 16 then pal := '{}'; end if;
    end if;

    if changed = 0 then return 0; end if;
    insert into mc.chunk_section as s (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data)
    values (p_dim, p_cx, p_cz, p_sy, bc, fc, pal, bits, data, sec.biome_palette, sec.biome_bits, sec.biome_data)
    on conflict (dimension, cx, cz, sy) do update
       set block_count = excluded.block_count, fluid_count = excluded.fluid_count, palette = excluded.palette, bits = excluded.bits, data = excluded.data;
    update mc.chunk c set version = c.version + 1, dirty = true where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    insert into mc.block_event (dimension, x, y, z, old_state, new_state)
    select p_dim, p_cx * 16 + (e.i & 15), p_sy * 16 + (e.i >> 8), p_cz * 16 + ((e.i >> 4) & 15), e.o, e.n
      from unnest(ev_idx, ev_old, ev_new) e(i, o, n);
    return changed;
end $$;

create or replace function mc.set_block(p_dim text, x int, y int, z int, p_block text) returns boolean language sql volatile as $$
  select mc.edit_section(p_dim, x >> 4, y >> 4, z >> 4, array[mc.section_idx(x, y, z)], array[p_block]) > 0 $$;

create or replace function mc.set_blocks(p_dim text, xs int[], ys int[], zs int[], blocks text[]) returns int language plpgsql volatile as $$
declare
    g     record;
    total int := 0;
begin
    if cardinality(xs) <> cardinality(ys) or cardinality(xs) <> cardinality(zs) or cardinality(xs) <> cardinality(blocks) then
        raise exception 'set_blocks: the four arrays must have the same length';
    end if;
    -- sorted by section so concurrent batches lock in the same order
    for g in
        select t.x >> 4 as cx, t.y >> 4 as sy, t.z >> 4 as cz,
               array_agg(mc.section_idx(t.x, t.y, t.z) order by t.o) as idxs, array_agg(t.b order by t.o) as names
          from unnest(xs, ys, zs, blocks) with ordinality t(x, y, z, b, o)
         group by 1, 2, 3 order by 1, 3, 2
    loop
        total := total + mc.edit_section(p_dim, g.cx, g.sy, g.cz, g.idxs, g.names);
    end loop;
    return total;
end $$;

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
begin
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if lo_y < d.min_y or hi_y >= d.min_y + d.height then raise exception 'fill is outside dimension % (y % .. %)', p_dim, d.min_y, d.min_y + d.height - 1; end if;
    for v_cx in (lo_x >> 4) .. (hi_x >> 4) loop
      for v_cz in (lo_z >> 4) .. (hi_z >> 4) loop
        for v_sy in (lo_y >> 4) .. (hi_y >> 4) loop
            a_x := greatest(lo_x, v_cx * 16); b_x := least(hi_x, v_cx * 16 + 15);
            a_y := greatest(lo_y, v_sy * 16); b_y := least(hi_y, v_sy * 16 + 15);
            a_z := greatest(lo_z, v_cz * 16); b_z := least(hi_z, v_cz * 16 + 15);
            covered := covered + (b_x - a_x + 1) * (b_y - a_y + 1) * (b_z - a_z + 1);
            if b_x - a_x = 15 and b_y - a_y = 15 and b_z - a_z = 15 then
                -- whole section: becomes a single-value section, nothing to unpack
                insert into mc.chunk (dimension, cx, cz) values (p_dim, v_cx, v_cz) on conflict do nothing;
                insert into mc.chunk_section as s (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette)
                values (p_dim, v_cx, v_cz, v_sy, case when mc.is_air(nm) then 0 else 4096 end, case when mc.has_fluid(nm) then 4096 else 0 end,
                        array[nm], 0, '\x', array[d.default_biome])
                on conflict (dimension, cx, cz, sy) do update
                   set block_count = excluded.block_count, fluid_count = excluded.fluid_count, palette = excluded.palette, bits = 0, data = '\x';
                update mc.chunk c set version = c.version + 1, dirty = true where c.dimension = p_dim and c.cx = v_cx and c.cz = v_cz;
                insert into mc.block_event (kind, dimension, x, y, z, old_state, new_state) values ('section', p_dim, v_cx * 16, v_sy * 16, v_cz * 16, '*', nm);
            else
                idxs := array(select mc.section_idx(x, y, z) from generate_series(a_x, b_x) x, generate_series(a_y, b_y) y, generate_series(a_z, b_z) z);
                perform mc.edit_section(p_dim, v_cx, v_sy, v_cz, idxs, array_fill(nm, array[cardinality(idxs)]), true);
            end if;
        end loop;
      end loop;
    end loop;
    return covered;
end $$;

------------------------------------------------------------------------------------------------ readable view
-- The non-air blocks of one stored section as rows.  Palette sections test "is air" once per palette entry, not once per block.
create or replace function mc.section_blocks(s mc.chunk_section, include_air boolean default false)
returns table (x int, y int, z int, block text) language sql stable as $$
  select s.cx * 16 + (u.i & 15), s.sy * 16 + (u.i >> 8), s.cz * 16 + ((u.i >> 4) & 15),
         case when cardinality(s.palette) = 0 then mc.state_name(u.e) else s.palette[u.e + 1] end
  from (select o - 1 as i, e from unnest(mc.unpack_longs(s.data, s.bits, 4096)) with ordinality t(e, o)) u,
       lateral (select array(select mc.is_air(p) from unnest(s.palette) with ordinality q(p, o) order by o) as air) a
  where include_air
     or not (case when cardinality(s.palette) = 0 then mc.is_air(mc.state_name(u.e)) else a.air[u.e + 1] end) $$;

-- Every non-air block of every stored section.  An unrestricted scan: Postgres cannot turn "WHERE x = 5" into a section lookup, because x is computed
-- from the section and the index inside it.  Use mc.blocks_in / mc.block_at for anything but small worlds (see docs/WORLD.md for measurements).
create or replace view mc.blocks as
  select s.dimension, b.x, b.y, b.z, b.block
  from mc.chunk_section s cross join lateral mc.section_blocks(s) b;

create or replace function mc.blocks_in(p_dim text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, include_air boolean default false)
returns table (dimension text, x int, y int, z int, block text) language sql stable as $$
  select s.dimension, b.x, b.y, b.z, b.block
  from mc.chunk_section s cross join lateral mc.section_blocks(s, include_air) b
  where s.dimension = p_dim
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
