-- World storage.  Sections are stored in the Minecraft WIRE format (palette + packed longs) so that sending a chunk never re-packs.
-- Everything here persists (no UNLOGGED) except the transient block_event queue.
--
--   mc.dimension / mc.world   what exists
--   mc.chunk                  per chunk: heightmaps (readable smallint[256]), edit version, dirty flag
--   mc.chunk_section          one 16x16x16 section: block palette (names), bits per entry, packed longs; biome palette likewise
--   mc.chunk_light            light layers (sky / block) per chunk, one row per layer index
--   mc.chunk_cache            finished, framed level_chunk_with_light packets keyed by chunk version
--   mc.block_event            block changes waiting to be broadcast (unlogged, consumed by the tick)
--
-- Conventions: x, y, z are absolute block coordinates; a chunk is (x >> 4, z >> 4); a section is y >> 4 (absolute, so -4 .. 19 in the overworld);
-- the index of a block inside its section is ((y & 15) << 8) | ((z & 15) << 4) | (x & 15), exactly vanilla's.

------------------------------------------------------------------------------------------------ registries owned by the world
-- Data-driven registry ids the client needs (they come from the registry_data sent in configuration).
-- Loaded by tools/load_world_ref.py from a capture; biome ids are the alphabetical rank of the key.
create table if not exists mc.biome (
    name text primary key,        -- minecraft:plains
    id   int  not null unique
);
create table if not exists mc.dimension_type (
    name text primary key,        -- minecraft:overworld
    id   int  not null unique
);

create table if not exists mc.dimension (
    name          text primary key,                      -- minecraft:overworld
    type          text not null default 'minecraft:overworld',
    min_y         int  not null default -64,
    height        int  not null default 384,
    default_biome text not null default 'minecraft:plains',
    spawn_x       int  not null default 0,
    spawn_y       int  not null default -60,
    spawn_z       int  not null default 0,
    check (min_y % 16 = 0 and height % 16 = 0 and height > 0)
);

create table if not exists mc.world (
    name              text primary key default 'world',
    seed              bigint not null default 0,
    default_dimension text references mc.dimension(name),
    created_at        timestamptz not null default now()
);

insert into mc.dimension (name) values ('minecraft:overworld') on conflict do nothing;
insert into mc.world (name, default_dimension) values ('world', 'minecraft:overworld') on conflict do nothing;

-- The world code looks block states up by NAME constantly (palette -> wire ids, canonical names of edits).  The unique btree on ref.block_state(name) pays a
-- locale-aware string comparison at every level (about 30 us per probe on 35,723 rows); a hash index answers an equality probe in about 7 us.
create index if not exists block_state_name_hash on ref.block_state using hash (name);

------------------------------------------------------------------------------------------------ chunk tables
create table if not exists mc.chunk (
    dimension text   not null references mc.dimension(name),
    cx        int    not null,
    cz        int    not null,
    status    text   not null default 'minecraft:full',
    version   bigint not null default 0,         -- bumped by every edit; mc.chunk_cache.version must equal it
    dirty     boolean not null default true,     -- light needs recomputing before the next send
    hm_dirty  boolean not null default false,    -- heightmaps need a FULL recompute (set by operations that cannot maintain them, e.g. whole-section fills);
                                                 -- edits through mc.edit_section keep them exact incrementally
    -- 256 values each, index = x_local + 16 * z_local, value = (top y + 1) - min_y, 0 for an empty column
    hm_motion_blocking           smallint[],
    hm_motion_blocking_no_leaves smallint[],
    hm_world_surface             smallint[],
    -- CACHE KEY of the light rows: the inputs they were computed from (the WORLD_SURFACE heightmap and the index of the highest non-empty section).
    -- mc.compute_light skips the work when both still match; NULL means "unknown, recompute".  Light is a pure function of these two values.
    light_ws  smallint[],
    light_top smallint,
    primary key (dimension, cx, cz)
) with (fillfactor = 70);

-- Databases created before the cache key existed: add the columns.  mc.gen_template (sql/245, a derived cache) stores mc.chunk rows, which blocks
-- ALTER TABLE, so it is dropped first; sql/245 creates it again (and it is rebuilt on first use).
do $$
begin
    if not exists (select 1 from pg_attribute where attrelid = 'mc.chunk'::regclass and attname = 'light_ws' and not attisdropped) then
        drop table if exists mc.gen_template;
        alter table mc.chunk add column light_ws smallint[], add column light_top smallint;
    end if;
end $$;

create table if not exists mc.chunk_section (
    dimension     text     not null,
    cx            int      not null,
    cz            int      not null,
    sy            int      not null,               -- absolute section index (y >> 4)
    block_count   smallint not null default 0,     -- non-air blocks
    fluid_count   smallint not null default 0,     -- blocks that contain a fluid
    palette       text[]   not null default array['minecraft:air'],   -- block-state names in insertion order; EMPTY means the global palette (entries are state ids)
    bits          smallint not null default 0,     -- bits per entry as written on the wire: 0 (single value), 4..8 (palette), 16 (global)
    data          bytea    not null default '\x',  -- packed longs, big-endian, NO length prefix: 4096 entries, vanilla's layout (no entry spans two longs)
    biome_palette text[]   not null default array['minecraft:plains'],
    biome_bits    smallint not null default 0,     -- 0 (single), 1..3 (palette), 7 (global)
    biome_data    bytea    not null default '\x',  -- 64 entries
    primary key (dimension, cx, cz, sy),
    foreign key (dimension, cx, cz) references mc.chunk(dimension, cx, cz) on delete cascade,
    check (bits in (0, 4, 5, 6, 7, 8, 16)),
    check (biome_bits in (0, 1, 2, 3, 7))
) with (fillfactor = 70, toast_tuple_target = 8160);   -- keep sections inline: byte loops over a detoasted value are quadratic
alter table mc.chunk_section alter column data set storage main;
alter table mc.chunk_section alter column palette set storage main;
alter table mc.chunk_section alter column biome_data set storage main;

-- Light layers.  idx 0 is the layer below the world, idx 1 is the lowest section, ... one more layer above the top section.
-- kind: 'data' = 2048 bytes of nibbles follow (index (y << 8 | z << 4 | x), low nibble first); 'empty' = all zero (sent only as a mask bit); NULL = layer absent.
create table if not exists mc.chunk_light (
    dimension  text     not null,
    cx         int      not null,
    cz         int      not null,
    idx        smallint not null,
    sky_kind   text check (sky_kind in ('data', 'empty')),
    sky        bytea,
    block_kind text check (block_kind in ('data', 'empty')),
    block      bytea,
    primary key (dimension, cx, cz, idx),
    foreign key (dimension, cx, cz) references mc.chunk(dimension, cx, cz) on delete cascade
) with (fillfactor = 70);

create table if not exists mc.chunk_cache (
    dimension text   not null,
    cx        int    not null,
    cz        int    not null,
    version   bigint not null,
    packet    bytea  not null,           -- framed: [length][id][body]
    primary key (dimension, cx, cz),
    foreign key (dimension, cx, cz) references mc.chunk(dimension, cx, cz) on delete cascade
) with (fillfactor = 70);

-- Block entities (chests, signs, banners, ...).  nbt is the NBT exactly as the chunk packet carries it: '\x00' for none, otherwise 0x0a and the compound
-- payload (network NBT has no root name).  Kept as bytes for now: a readable NBT representation is future work (docs/WORLD.md).
-- seq fixes the order in the packet (vanilla's is a hash-map order; clients do not care).
create table if not exists mc.block_entity (
    dimension text   not null,
    cx        int    not null,
    cz        int    not null,
    x         int    not null,
    y         int    not null,
    z         int    not null,
    type      text   not null,                     -- minecraft:chest
    nbt       bytea  not null default '\x00',
    seq       bigint generated always as identity,
    primary key (dimension, x, y, z),
    foreign key (dimension, cx, cz) references mc.chunk(dimension, cx, cz) on delete cascade
);
create index if not exists block_entity_chunk_idx on mc.block_entity (dimension, cx, cz, seq);

-- Block changes for the tick to broadcast.  Transient, hence unlogged.
-- kind 'block': one position changed (x, y, z; old and new state).  kind 'cells': a fill changed many positions of ONE section: x, y, z = the section's lowest corner,
-- cells = 512 bytes, bit (y << 8 | z << 4 | x) of the section set for every position that changed (bit i is bit i % 8 of byte i / 8), new_state = the block placed,
-- old_state = '*'.  The broadcast turns the positions of one section and tick into block_update (one position) or section_blocks_update (two or more), as vanilla does
-- (docs/WORLD.md "Block change packets").  kind 'section' (a whole section replaced, the chunk is re-sent) is no longer written by the server; the broadcast still understands it.
create unlogged table if not exists mc.block_event (
    id        bigint generated always as identity primary key,
    kind      text not null default 'block' check (kind in ('block', 'section', 'cells')),
    dimension text not null,
    x         int  not null,
    y         int  not null,
    z         int  not null,
    old_state text not null,                 -- '*' for a section or cells event
    new_state text not null,
    at        timestamptz not null default now(),
    cells     bytea
);
do $$
begin
    -- a database created before 'cells' existed: add the column and widen the check (the table is transient, so this is cheap)
    if not exists (select 1 from information_schema.columns where table_schema = 'mc' and table_name = 'block_event' and column_name = 'cells') then
        alter table mc.block_event add column cells bytea;
        alter table mc.block_event drop constraint if exists block_event_kind_check;
        alter table mc.block_event add constraint block_event_kind_check check (kind in ('block', 'section', 'cells'));
    end if;
end $$;

-- Layers of the default flat preset (vanilla: bedrock, 2 dirt, grass_block from the bottom of the world).
create table if not exists mc.flat_layer (
    dimension text not null references mc.dimension(name),
    y         int  not null,
    block     text not null,
    primary key (dimension, y)
);
insert into mc.flat_layer (dimension, y, block) values
    ('minecraft:overworld', -64, 'minecraft:bedrock'),
    ('minecraft:overworld', -63, 'minecraft:dirt'),
    ('minecraft:overworld', -62, 'minecraft:dirt'),
    ('minecraft:overworld', -61, 'minecraft:grass_block')
on conflict do nothing;

------------------------------------------------------------------------------------------------ bit packing
-- ceil(log2(n)); 0 for n <= 1.  Uses the binary length of n - 1, which is exact (no floating point).
create or replace function mc.ceillog2(n int) returns int language sql immutable parallel safe as $$
  select length(ltrim((greatest(n, 1) - 1)::bit(32)::text, '0')) $$;

-- Vanilla's SimpleBitStorage: floor(64 / bits) entries per long, entry i at bit (i % per) * bits (LSB first), no entry spans two longs,
-- each long written big-endian.  bits must be 1..16.
create or replace function mc.pack_longs(vals int[], bits int) returns bytea language plpgsql immutable parallel safe as $$
declare
    vpl   int := 64 / bits;
    n     int := coalesce(array_length(vals, 1), 0);
    words bigint[] := array_fill(0::bigint, array[greatest((n + vpl - 1) / vpl, 1)]);
    i     int;
    w     int;
begin
    for i in 0 .. n - 1 loop
        w := i / vpl + 1;
        words[w] := words[w] | (vals[i + 1]::bigint << ((i % vpl) * bits));
    end loop;
    if n = 0 then return '\x'; end if;
    return (select string_agg(int8send(x), ''::bytea order by o) from unnest(words) with ordinality t(x, o));
end $$;

-- Inverse of pack_longs for n entries.  Entries are at most 16 bits and never straddle a long, so three bytes always hold one.
create or replace function mc.unpack_longs(d bytea, bits int, n int) returns int[] language sql immutable parallel safe as $$
  select case when bits = 0 then array_fill(0, array[n]) else
    array(
      select ((((get_byte(d, k))
              | ((case when k - 1 >= base then get_byte(d, k - 1) else 0 end) << 8)
              | ((case when k - 2 >= base then get_byte(d, k - 2) else 0 end) << 16)) >> (p % 8))
              & ((1 << bits) - 1))
      from (select i, base, p, base + 7 - p / 8 as k
            from (select i, (i / (64 / bits)) * 8 as base, (i % (64 / bits)) * bits as p from generate_series(0, n - 1) i) q) r
      order by i)
  end $$;

-- One entry of a packed array.
create or replace function mc.entry_at(bits int, d bytea, idx int) returns int language sql immutable parallel safe as $$
  select case when bits = 0 then 0
    else ((proto.i64_read(d, (idx / (64 / bits)) * 8) >> ((idx % (64 / bits)) * bits)) & ((1 << bits) - 1))::int end $$;

-- Index of block (x, y, z) inside its section.
create or replace function mc.section_idx(x int, y int, z int) returns int language sql immutable parallel safe as $$
  select ((y & 15) << 8) | ((z & 15) << 4) | (x & 15) $$;

-- Bit set as the protocol writes it: VarInt byte count, then little-endian bytes (bit i is byte i/8, bit i%8).
create or replace function mc.bitset_wire(bits_set int[]) returns bytea language plpgsql immutable parallel safe as $$
declare n int; out bytea; b int;
begin
    if bits_set is null or cardinality(bits_set) = 0 then return '\x00'; end if;
    n := (select max(x) from unnest(bits_set) x) / 8 + 1;
    out := decode(repeat('00', n), 'hex');
    foreach b in array bits_set loop
        out := set_byte(out, b / 8, get_byte(out, b / 8) | (1 << (b % 8)));
    end loop;
    return proto.varint(n) || out;
end $$;

------------------------------------------------------------------------------------------------ block state helpers
-- Air variants and fluid-bearing states, from names alone (no table needed; hand-derived, see docs/WORLD.md).
create or replace function mc.is_air(state text) returns boolean language sql immutable parallel safe as $$
  select split_part(state, '[', 1) in ('minecraft:air', 'minecraft:cave_air', 'minecraft:void_air') $$;
create or replace function mc.has_fluid(state text) returns boolean language sql immutable parallel safe as $$
  select split_part(state, '[', 1) in ('minecraft:water', 'minecraft:lava', 'minecraft:bubble_column', 'minecraft:kelp', 'minecraft:kelp_plant',
                                       'minecraft:seagrass', 'minecraft:tall_seagrass')
         or state like '%waterlogged=true%' $$;

-- A state name as stored in ref.block_state; a bare block name resolves to that block's default state.
create or replace function mc.canon_state(name text) returns text language sql stable parallel safe as $$
  select coalesce(
    (select s.name from ref.block_state s where s.name = canon_state.name),
    (select s.name from ref.block b join ref.block_state s on s.state_id = b.default_state where b.name = canon_state.name),
    (select proto.bad('unknown block state ' || canon_state.name)::text)) $$;

-- Accepts a full state name or a bare block name (its default state).
create or replace function mc.state_id(name text) returns int language sql stable parallel safe as $$
  select s.state_id from ref.block_state s where s.name = mc.canon_state(state_id.name) $$;

create or replace function mc.state_name(id int) returns text language sql stable parallel safe as $$
  select s.name from ref.block_state s where s.state_id = id $$;

create or replace function mc.global_block_bits() returns int language sql stable parallel safe as $$
  select mc.ceillog2((select max(state_id) + 1 from ref.block_state)) $$;
create or replace function mc.global_biome_bits() returns int language sql stable parallel safe as $$
  select mc.ceillog2((select max(id) + 1 from mc.biome)) $$;
