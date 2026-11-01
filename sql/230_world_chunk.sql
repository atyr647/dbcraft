-- Chunk packet encoding: minecraft:level_chunk_with_light, protocol 777 (26.3).  Layout (read from the 26.3 classes and checked against captured packets):
--
--   int x, int z
--   heightmaps : VarInt count, then per entry: VarInt type id, VarInt long count, longs (9 bits per column at height 384, 7 per long)
--   sections   : VarInt byte length, then per section (bottom to top):
--                  short block_count, short fluid_count,
--                  blocks container (u8 bits; palette; longs), biomes container (same shape, 64 entries)
--                  palette = single value: VarInt id | linear/hashed: VarInt size + VarInt ids | global (bits above 8 / 3): none.  Longs have NO length prefix.
--   block entities : VarInt count, then per entry: byte (x << 4 | z), short y, VarInt type id, NBT (see mc.block_entity)
--   light      : 4 bit sets (sky, block, empty sky, empty block; each VarInt byte count + little-endian bytes),
--                list of sky arrays, list of block arrays (each: VarInt count, then VarInt 2048 + bytes)

create or replace function mc.biome_id(p_name text) returns int language sql stable parallel safe as $$
  select id from mc.biome where name = p_name $$;

-- Resolve a palette of state names to global ids, in order.  Raises when a name is unknown.
create or replace function mc.palette_ids(pal text[]) returns int[] language plpgsql stable parallel safe as $$
declare ids int[];
begin
    ids := array(select s.state_id from unnest(pal) with ordinality p(n, o) join ref.block_state s on s.name = p.n order by p.o);
    if cardinality(ids) <> cardinality(pal) then raise exception 'palette holds an unknown block state: %', pal; end if;
    return ids;
end $$;

create or replace function mc.biome_palette_ids(pal text[]) returns int[] language plpgsql stable parallel safe as $$
declare ids int[];
begin
    ids := array(select b.id from unnest(pal) with ordinality p(n, o) join mc.biome b on b.name = p.n order by p.o);
    if cardinality(ids) <> cardinality(pal) then raise exception 'biome palette holds an unknown biome: %', pal; end if;
    return ids;
end $$;

create or replace function mc.varints(ids int[]) returns bytea language sql immutable parallel safe as $$
  select coalesce(string_agg(proto.varint(x), ''::bytea order by o), '\x') from unnest(ids) with ordinality t(x, o) $$;

-- A paletted container as written on the wire.
create or replace function mc.container_wire(bits int, ids int[], global_palette boolean, d bytea) returns bytea language sql immutable parallel safe as $$
  select case when bits = 0 then proto.i8(0) || proto.varint(ids[1])
              when global_palette then proto.i8(bits) || d
              else proto.i8(bits) || proto.varint(cardinality(ids)) || mc.varints(ids) || d end $$;

-- One stored section as written inside the chunk packet.
-- plpgsql with two lookups (palette ids as VarInts in one query each) instead of a chain of small SQL functions, each planned again on every call: 1.0 ms -> 0.1 ms.
create or replace function mc.section_wire(s mc.chunk_section) returns bytea language plpgsql stable parallel safe set plan_cache_mode = force_generic_plan as $$
declare
    n     int;
    pb    bytea;
    blk   bytea;
    bio   bytea;
begin
    if cardinality(s.palette) = 0 then
        blk := proto.i8(s.bits) || s.data;                                       -- global palette: the entries are state ids
    else
        select count(*), string_agg(proto.varint(b.state_id), ''::bytea order by p.o) into n, pb
          from unnest(s.palette) with ordinality p(nm, o) join ref.block_state b on b.name = p.nm;
        if n <> cardinality(s.palette) then raise exception 'palette holds an unknown block state: %', s.palette; end if;
        blk := case when s.bits = 0 then proto.i8(0) || pb else proto.i8(s.bits) || proto.varint(n) || pb || s.data end;
    end if;
    if cardinality(s.biome_palette) = 0 then
        bio := proto.i8(s.biome_bits) || s.biome_data;
    else
        select count(*), string_agg(proto.varint(b.id), ''::bytea order by p.o) into n, pb
          from unnest(s.biome_palette) with ordinality p(nm, o) join mc.biome b on b.name = p.nm;
        if n <> cardinality(s.biome_palette) then raise exception 'biome palette holds an unknown biome: %', s.biome_palette; end if;
        bio := case when s.biome_bits = 0 then proto.i8(0) || pb else proto.i8(s.biome_bits) || proto.varint(n) || pb || s.biome_data end;
    end if;
    return proto.i16(s.block_count) || proto.i16(s.fluid_count) || blk || bio;
end $$;

-- A section that is not stored: all air, the dimension's default biome.
create or replace function mc.empty_section_wire(p_dim text) returns bytea language sql stable parallel safe as $$
  select proto.i16(0) || proto.i16(0) || proto.i8(0) || proto.varint(0) || proto.i8(0)
      || proto.varint((select b.id from mc.dimension d join mc.biome b on b.name = d.default_biome where d.name = p_dim)) $$;

-- Heightmap types sent to the client.  The vanilla server writes them in HashMap order, which varies with the JVM run; this is the order of the reference
-- capture (MOTION_BLOCKING 4, MOTION_BLOCKING_NO_LEAVES 5, WORLD_SURFACE 1).  Clients accept any order.
-- The three arrays are packed in one pass: entry k goes to bit (k mod per-long) * bits of long k / per-long, as in mc.pack_longs, but as one grouped
-- aggregate instead of three plpgsql loops of 256 steps (1.0 ms -> 0.05 ms).
create or replace function mc.heightmaps_wire3(hm_mb smallint[], hm_nl smallint[], hm_ws smallint[], p_height int) returns bytea language plpgsql immutable parallel safe set plan_cache_mode = force_generic_plan as $$
declare
    bits int := mc.ceillog2(p_height + 1);
    vpl  int := 64 / bits;
    w1 bytea; w2 bytea; w3 bytea;
begin
    select string_agg(int8send(a), ''::bytea order by n), string_agg(int8send(b), ''::bytea order by n), string_agg(int8send(c), ''::bytea order by n)
      into w1, w2, w3
      from (select k / vpl as n,
                   bit_or(hm_mb[k + 1]::bigint << ((k % vpl) * bits)) as a,
                   bit_or(hm_nl[k + 1]::bigint << ((k % vpl) * bits)) as b,
                   bit_or(hm_ws[k + 1]::bigint << ((k % vpl) * bits)) as c
              from generate_series(0, cardinality(hm_mb) - 1) k group by 1) q;
    return proto.varint(3)
        || proto.varint(4) || proto.varint(octet_length(w1) / 8) || w1
        || proto.varint(5) || proto.varint(octet_length(w2) / 8) || w2
        || proto.varint(1) || proto.varint(octet_length(w3) / 8) || w3;
end $$;

create or replace function mc.heightmaps_wire(c mc.chunk, p_height int) returns bytea language sql immutable parallel safe as $$
  select mc.heightmaps_wire3(c.hm_motion_blocking, c.hm_motion_blocking_no_leaves, c.hm_world_surface, p_height) $$;

-- A layer-index set as the protocol writes a bit set (VarInt byte count, then little-endian bytes), from a 64-bit mask (layer i = bit i).
create or replace function mc.mask_wire(m bigint) returns bytea language plpgsql immutable parallel safe as $$
declare n int; o bytea; k int;
begin
    if m = 0 then return '\x00'; end if;
    n := (length(ltrim(m::bit(64)::text, '0')) + 7) / 8;
    o := proto.varint(n);
    for k in 0 .. n - 1 loop o := o || set_byte('\x00'::bytea, 0, ((m >> (8 * k)) & 255)::int); end loop;
    return o;
end $$;

-- Light section of the packet: masks, then the sky arrays, then the block arrays, each in layer order.
-- One pass over the chunk's light rows (the first version scanned them eleven times and re-planned on every call: 0.84 ms -> 0.08 ms).  The masks need
-- layer indexes below 63; a taller world falls back to the generic bit-set code.
create or replace function mc.light_wire(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql stable parallel safe set plan_cache_mode = force_generic_plan as $$
declare
    r    bytea;
    mx   int;
begin
    select max(idx) into mx from mc.chunk_light where dimension = p_dim and cx = p_cx and cz = p_cz;
    if mx is not null and mx > 62 then return mc.light_wire_generic(p_dim, p_cx, p_cz); end if;
    select mc.mask_wire(coalesce(bit_or(1::bigint << idx) filter (where sky_kind = 'data'), 0))
        || mc.mask_wire(coalesce(bit_or(1::bigint << idx) filter (where block_kind = 'data'), 0))
        || mc.mask_wire(coalesce(bit_or(1::bigint << idx) filter (where sky_kind = 'empty'), 0))
        || mc.mask_wire(coalesce(bit_or(1::bigint << idx) filter (where block_kind = 'empty'), 0))
        || proto.varint(count(*) filter (where sky_kind = 'data')::int)
        || coalesce(string_agg(proto.varint(octet_length(sky)) || sky, ''::bytea order by idx) filter (where sky_kind = 'data'), '\x')
        || proto.varint(count(*) filter (where block_kind = 'data')::int)
        || coalesce(string_agg(proto.varint(octet_length(block)) || block, ''::bytea order by idx) filter (where block_kind = 'data'), '\x')
      into r
      from mc.chunk_light where dimension = p_dim and cx = p_cx and cz = p_cz;
    return r;
end $$;

-- The original formulation, kept for worlds taller than 62 sections (the fast version packs the layer sets into one 64-bit mask).
create or replace function mc.light_wire_generic(p_dim text, p_cx int, p_cz int) returns bytea language sql stable parallel safe as $$
  with l as (select * from mc.chunk_light where dimension = p_dim and cx = p_cx and cz = p_cz)
  select mc.bitset_wire(array(select idx::int from l where sky_kind = 'data' order by idx))
      || mc.bitset_wire(array(select idx::int from l where block_kind = 'data' order by idx))
      || mc.bitset_wire(array(select idx::int from l where sky_kind = 'empty' order by idx))
      || mc.bitset_wire(array(select idx::int from l where block_kind = 'empty' order by idx))
      || proto.varint((select count(*)::int from l where sky_kind = 'data'))
      || coalesce((select string_agg(proto.varint(octet_length(sky)) || sky, ''::bytea order by idx) from l where sky_kind = 'data'), '\x')
      || proto.varint((select count(*)::int from l where block_kind = 'data'))
      || coalesce((select string_agg(proto.varint(octet_length(block)) || block, ''::bytea order by idx) from l where block_kind = 'data'), '\x') $$;

-- Block entity list of the packet: VarInt count, then per entry packed x/z (one byte, x << 4 | z), y (short), block entity type id (VarInt), NBT.
-- Most chunks have none: one existence check answers that without the join and the aggregate.
create or replace function mc.block_entities_wire(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql stable parallel safe set plan_cache_mode = force_generic_plan as $$
begin
    if not exists (select 1 from mc.block_entity e where e.dimension = p_dim and e.cx = p_cx and e.cz = p_cz) then return '\x00'; end if;
    return (select proto.varint(count(*)::int)
                || coalesce(string_agg(proto.i8(((e.x & 15) << 4) | (e.z & 15)) || proto.i16(e.y) || proto.varint(r.protocol_id) || e.nbt, ''::bytea order by e.seq), '\x'::bytea)
              from mc.block_entity e
              join ref.registry r on r.registry = 'minecraft:block_entity_type' and r.name = e.type
             where e.dimension = p_dim and e.cx = p_cx and e.cz = p_cz);
end $$;

-- The body of minecraft:level_chunk_with_light for a chunk whose derived data is current (see mc.ensure_chunk_current).  NULL when the chunk does not exist.
-- One lookup of the chunk and its dimension, one pass over the sections, then the parts from the single-pass helpers above (see docs/PERF-EDIT.md).
create or replace function mc.chunk_packet_body(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql stable set plan_cache_mode = force_generic_plan as $$
declare
    v_min_y  int;
    v_height int;
    bid      int;
    h_mb     smallint[];
    h_nl     smallint[];
    h_ws     smallint[];
    secs     bytea;
    empty    bytea;
begin
    select d.min_y, d.height, (select b.id from mc.biome b where b.name = d.default_biome), c.hm_motion_blocking, c.hm_motion_blocking_no_leaves, c.hm_world_surface
      into v_min_y, v_height, bid, h_mb, h_nl, h_ws
      from mc.chunk c join mc.dimension d on d.name = c.dimension
     where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    if not found then return null; end if;
    if h_ws is null then raise exception 'chunk %,% has no heightmaps; call mc.ensure_chunk_current first', p_cx, p_cz; end if;
    empty := proto.i16(0) || proto.i16(0) || proto.i8(0) || proto.varint(0) || proto.i8(0) || proto.varint(bid);     -- a section that is not stored: all air, default biome
    select string_agg(case when s.sy is null then empty else mc.section_wire(s) end, ''::bytea order by g)
      into secs
      from generate_series(v_min_y >> 4, ((v_min_y + v_height) >> 4) - 1) g
      left join mc.chunk_section s on s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = g;
    return proto.i32(p_cx) || proto.i32(p_cz)
        || mc.heightmaps_wire3(h_mb, h_nl, h_ws, v_height)
        || proto.varint(octet_length(secs)) || secs
        || mc.block_entities_wire(p_dim, p_cx, p_cz)
        || mc.light_wire(p_dim, p_cx, p_cz);
end $$;

create or replace function mc.chunk_packet_id() returns int language sql stable parallel safe as $$
  select protocol_id from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:level_chunk_with_light' $$;

-- Framed packet built (and cached) the generic way: brings the derived data current, then encodes.  NULL when the chunk does not exist.
create or replace function mc.chunk_packet_build(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    v   bigint;
    pkt bytea;
begin
    perform mc.ensure_chunk_current(p_dim, p_cx, p_cz);
    select c.version into v from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    if not found then return null; end if;
    select k.packet into pkt from mc.chunk_cache k where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz and k.version = v;
    if found then return pkt; end if;
    pkt := proto.frame(mc.chunk_packet_id(), mc.chunk_packet_body(p_dim, p_cx, p_cz));
    -- with compression on, the compressed frame is cached with the packet (sql/440): payload = packet id + body = what follows the length VarInt
    insert into mc.chunk_cache (dimension, cx, cz, version, packet, packet_z)
    values (p_dim, p_cx, p_cz, v, pkt, case when mc.compression_enabled() then mc.z_frame(substring(pkt from (select nxt from proto.varint_read(pkt, 0)) + 1)) end)
    on conflict (dimension, cx, cz) do update set version = excluded.version, packet = excluded.packet, packet_z = excluded.packet_z;
    return pkt;
end $$;

-- Framed packet, rebuilt only when the chunk changed since the cached copy (compare mc.chunk.version).  NULL when the chunk does not exist.
-- The common case (nothing changed, packet cached) is ONE index lookup with no row lock: the first version took a FOR UPDATE lock on the chunk row on every
-- call (mc.ensure_chunk_current), which cost more than the rest of the read together.  Anything else falls through to mc.chunk_packet_build.
-- PL/pgSQL on purpose: a LANGUAGE sql function that cannot be inlined is re-planned on every call (0.5 ms here), PL/pgSQL keeps its plans.
create or replace function mc.chunk_packet(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql volatile as $$
declare pkt bytea;
begin
    select k.packet into pkt
      from mc.chunk c join mc.chunk_cache k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version
     where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz and not c.dirty and not c.hm_dirty and c.hm_world_surface is not null;
    if found then return pkt; end if;
    return mc.chunk_packet_build(p_dim, p_cx, p_cz);
end $$;
