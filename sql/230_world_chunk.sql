-- Chunk packet encoding: minecraft:level_chunk_with_light, protocol 777 (26.3).  Layout (read from the 26.3 classes and checked against captured packets):
--
--   int x, int z
--   heightmaps : VarInt count, then per entry: VarInt type id, VarInt long count, longs (9 bits per column at height 384, 7 per long)
--   sections   : VarInt byte length, then per section (bottom to top):
--                  short block_count, short fluid_count,
--                  blocks container (u8 bits; palette; longs), biomes container (same shape, 64 entries)
--                  palette = single value: VarInt id | linear/hashed: VarInt size + VarInt ids | global (bits above 8 / 3): none.  Longs have NO length prefix.
--   block entities : VarInt count (always 0 here: block entities are not stored yet)
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
create or replace function mc.section_wire(s mc.chunk_section) returns bytea language sql stable parallel safe as $$
  select proto.i16(s.block_count) || proto.i16(s.fluid_count)
      || mc.container_wire(s.bits, case when cardinality(s.palette) > 0 then mc.palette_ids(s.palette) end, cardinality(s.palette) = 0, s.data)
      || mc.container_wire(s.biome_bits, case when cardinality(s.biome_palette) > 0 then mc.biome_palette_ids(s.biome_palette) end, cardinality(s.biome_palette) = 0, s.biome_data) $$;

-- A section that is not stored: all air, the dimension's default biome.
create or replace function mc.empty_section_wire(p_dim text) returns bytea language sql stable parallel safe as $$
  select proto.i16(0) || proto.i16(0) || proto.i8(0) || proto.varint(0) || proto.i8(0)
      || proto.varint((select b.id from mc.dimension d join mc.biome b on b.name = d.default_biome where d.name = p_dim)) $$;

-- Heightmap types sent to the client.  The vanilla server writes them in HashMap order, which varies with the JVM run; this is the order of the reference
-- capture (MOTION_BLOCKING 4, MOTION_BLOCKING_NO_LEAVES 5, WORLD_SURFACE 1).  Clients accept any order.
create or replace function mc.heightmaps_wire(c mc.chunk, p_height int) returns bytea language sql immutable parallel safe as $$
  select proto.varint(3)
      || proto.varint(4) || proto.varint(octet_length(w1) / 8) || w1
      || proto.varint(5) || proto.varint(octet_length(w2) / 8) || w2
      || proto.varint(1) || proto.varint(octet_length(w3) / 8) || w3
  from (select mc.pack_longs(c.hm_motion_blocking, mc.ceillog2(p_height + 1)) w1,
               mc.pack_longs(c.hm_motion_blocking_no_leaves, mc.ceillog2(p_height + 1)) w2,
               mc.pack_longs(c.hm_world_surface, mc.ceillog2(p_height + 1)) w3) q $$;

-- Light section of the packet: masks, then the sky arrays, then the block arrays, each in layer order.
create or replace function mc.light_wire(p_dim text, p_cx int, p_cz int) returns bytea language sql stable parallel safe as $$
  with l as (select * from mc.chunk_light where dimension = p_dim and cx = p_cx and cz = p_cz)
  select mc.bitset_wire(array(select idx::int from l where sky_kind = 'data' order by idx))
      || mc.bitset_wire(array(select idx::int from l where block_kind = 'data' order by idx))
      || mc.bitset_wire(array(select idx::int from l where sky_kind = 'empty' order by idx))
      || mc.bitset_wire(array(select idx::int from l where block_kind = 'empty' order by idx))
      || proto.varint((select count(*)::int from l where sky_kind = 'data'))
      || coalesce((select string_agg(proto.varint(octet_length(sky)) || sky, ''::bytea order by idx) from l where sky_kind = 'data'), '\x')
      || proto.varint((select count(*)::int from l where block_kind = 'data'))
      || coalesce((select string_agg(proto.varint(octet_length(block)) || block, ''::bytea order by idx) from l where block_kind = 'data'), '\x') $$;

-- The body of minecraft:level_chunk_with_light for a chunk whose derived data is current (see mc.ensure_chunk_current).  NULL when the chunk does not exist.
create or replace function mc.chunk_packet_body(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql stable as $$
declare
    d    mc.dimension%rowtype;
    c    mc.chunk%rowtype;
    secs bytea;
begin
    select * into d from mc.dimension where name = p_dim;
    select * into c from mc.chunk where dimension = p_dim and cx = p_cx and cz = p_cz;
    if not found then return null; end if;
    if c.hm_world_surface is null then raise exception 'chunk %,% has no heightmaps; call mc.ensure_chunk_current first', p_cx, p_cz; end if;
    select string_agg(case when s.sy is null then mc.empty_section_wire(p_dim) else mc.section_wire(s) end, ''::bytea order by g)
      into secs
      from generate_series(d.min_y >> 4, ((d.min_y + d.height) >> 4) - 1) g
      left join mc.chunk_section s on s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = g;
    return proto.i32(p_cx) || proto.i32(p_cz)
        || mc.heightmaps_wire(c, d.height)
        || proto.varint(octet_length(secs)) || secs
        || proto.varint(0)
        || mc.light_wire(p_dim, p_cx, p_cz);
end $$;

create or replace function mc.chunk_packet_id() returns int language sql stable parallel safe as $$
  select protocol_id from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:level_chunk_with_light' $$;

-- Framed packet, rebuilt only when the chunk changed since the cached copy (compare mc.chunk.version).  NULL when the chunk does not exist.
create or replace function mc.chunk_packet(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql volatile as $$
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
    insert into mc.chunk_cache (dimension, cx, cz, version, packet) values (p_dim, p_cx, p_cz, v, pkt)
    on conflict (dimension, cx, cz) do update set version = excluded.version, packet = excluded.packet;
    return pkt;
end $$;
