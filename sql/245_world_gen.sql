-- Chunk generation: the generator registry, the flat TEMPLATE, and set-based batch generation.
--
--   mc.generator              name -> batch function.  A generator is a function (dimension text, cxs int[], czs int[]) returning int that creates the
--                             chunks that do not exist yet (as ordinary rows: chunk, sections, light) and returns how many it created.  mc.dimension.generator
--                             says which one a dimension uses; a heavier terrain generator plugs in by inserting a row here.
--   mc.generate_batch         the dispatcher the generation queue (sql/430) calls.
--   mc.gen_template           DERIVED CACHE, rebuildable at any time: the rows of one generated flat chunk.  Every flat chunk of a dimension is the same except for
--                             its coordinates, so generating N chunks is one set-based copy of the template instead of N runs of the generic code.  The template
--                             is built by the reference implementation (mc.generate_flat_slow) and checked against vanilla by tests/sql/240; tests/sql/260 proves
--                             the copy is row-for-row and byte-for-byte identical to the reference.  It is rebuilt whenever its signature changes (layers,
--                             dimension shape, registries, generator version).
--   The chunk packet of an untouched generated chunk is the template's packet with the two coordinates (the first 8 bytes of the body) replaced, so the packet
--   cache is filled at generation time too (mc.chunk_cache; an edit bumps the chunk version and the next read rebuilds the packet the generic way).
--
-- The rows stay the source of truth: nothing here is read when sending except mc.chunk_cache, and that is checked against mc.chunk.version.

------------------------------------------------------------------------------------------------ the template
-- Bump when the generic generation, heightmap or light code changes in a way that alters its output: it invalidates every template.
create or replace function mc.gen_version() returns int language sql immutable parallel safe as $$ select 4 $$;     -- 3: template chunk rows carry the light cache key; 4: the template's compressed rest is zlib level 9 when the native deflate is installed (sql/950: the cached packet_z of a flat chunk is 130 bytes, was 1,100)

create table if not exists mc.gen_template (
    dimension  text primary key,                 -- the dimension it serves
    sig        text not null,                    -- mc.gen_stamp() at build time
    chunk      mc.chunk not null,                -- the template chunk's row (dimension, cx, cz ignored)
    sections   mc.chunk_section[] not null,      -- its stored sections, bottom to top (dimension, cx, cz ignored)
    light      mc.chunk_light[] not null,        -- its light rows
    pkt_prefix bytea not null,                   -- framed packet bytes before the coordinates
    pkt_suffix bytea not null,                   -- ... and after them
    built_at   timestamptz not null default now()
);
-- the compressed form of the same packet (sql/440): its frame is z_prefix, the zlib header, a stored block with the 9 bytes (packet id + coordinates) of the
-- chunk, z_rest (the rest of the packet compressed once), and the Adler-32 combined from the pieces
alter table mc.gen_template add column if not exists z_prefix bytea;
alter table mc.gen_template add column if not exists z_rest   bytea;
alter table mc.gen_template add column if not exists z_a_rest bigint;
alter table mc.gen_template add column if not exists z_l_rest int;
comment on table mc.gen_template is 'Derived cache: the rows of one generated flat chunk per dimension, rebuilt when mc.flat_signature changes. Safe to truncate.';

-- What the template depends on that no trigger watches: the generation code (mc.gen_version) and the reference data it encodes against.  Cheap (two index
-- lookups); compared on every use.  Changes to the dimension row, its flat layers or the biome registry invalidate the template through the triggers below.
create or replace function mc.gen_stamp() returns text language plpgsql stable as $$
begin
    return mc.gen_version() || '#' || (select max(state_id) from ref.block_state) || '#' || mc.chunk_packet_id();
end $$;

create or replace function mc.template_invalidate() returns trigger language plpgsql as $$
begin
    if tg_table_name = 'biome' then delete from mc.gen_template;
    elsif tg_table_name = 'dimension' then delete from mc.gen_template where dimension = coalesce(new.name, old.name);
    else delete from mc.gen_template where dimension = coalesce(new.dimension, old.dimension); end if;
    return null;
end $$;
drop trigger if exists template_invalidate on mc.flat_layer;
create trigger template_invalidate after insert or update or delete on mc.flat_layer for each row execute function mc.template_invalidate();
drop trigger if exists template_invalidate on mc.dimension;
create trigger template_invalidate after update of type, min_y, height, default_biome or delete on mc.dimension for each row execute function mc.template_invalidate();
drop trigger if exists template_invalidate on mc.biome;
create trigger template_invalidate after insert or update or delete on mc.biome for each statement execute function mc.template_invalidate();

-- The full signature (for tests and diagnostics): the stamp plus everything the triggers watch.
create or replace function mc.flat_signature(p_dim text) returns text language sql stable as $$
  select md5(concat_ws('#',
      mc.gen_stamp(),
      (select d.type || '|' || d.min_y || '|' || d.height || '|' || d.default_biome from mc.dimension d where d.name = p_dim),
      (select string_agg(f.y || ':' || f.block, ',' order by f.y) from mc.flat_layer f where f.dimension = p_dim),
      (select md5(string_agg(b.name || '=' || b.id, ',' order by b.id)) from mc.biome b))) $$;

create or replace function mc.ensure_flat_template(p_dim text) returns mc.gen_template language plpgsql volatile as $$
declare
    sig  text := mc.gen_stamp();
    t    mc.gen_template;
    d    mc.dimension;
    tdim text := 'dbcraft:template/' || p_dim;
    pkt  bytea;
    o1   int;
    hdr  int;
    pay  bytea;
    zr   bytea;
begin
    select * into t from mc.gen_template g where g.dimension = p_dim;
    if found and t.sig = sig then return t; end if;
    perform pg_advisory_xact_lock(hashtext('mc.gen_template:' || p_dim));      -- one rebuild at a time; the others wait and then find it done
    select * into t from mc.gen_template g where g.dimension = p_dim;
    if found and t.sig = sig then return t; end if;
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;

    -- Build the template in a scratch dimension, harvest its rows, remove the scratch rows again (all in this transaction, so nobody ever sees them).
    delete from mc.chunk where dimension = tdim;
    delete from mc.flat_layer where dimension = tdim;
    delete from mc.dimension where name = tdim;
    insert into mc.dimension (name, type, min_y, height, default_biome, spawn_x, spawn_y, spawn_z)
    values (tdim, d.type, d.min_y, d.height, d.default_biome, d.spawn_x, d.spawn_y, d.spawn_z);
    insert into mc.flat_layer (dimension, y, block) select tdim, f.y, f.block from mc.flat_layer f where f.dimension = p_dim;
    perform mc.generate_flat_slow(tdim, 0, 0, true);
    pkt := mc.chunk_packet(tdim, 0, 0);
    o1  := (select nxt from proto.varint_read(pkt, 0));
    hdr := (select nxt from proto.varint_read(pkt, o1));                         -- bytes of [length][packet id]; the body starts with int cx, int cz
    -- compressed form: payload = packet id + body; its first 9 bytes (id < 128, then the two coordinates) are spliced per chunk, the rest is compressed once
    pay := substring(pkt from o1 + 1);
    if mc.deflate_impl() = 'native' then
        -- a bare deflate stream (one final block, byte aligned at its end) follows the stored block as well as the SQL encoder's does; level 9 makes it 99 bytes instead of 1,071
        execute 'select dbcraft_zlib.deflate_raw($1, 9)' into zr using substring(pay from 10);
    else
        zr := mc.deflate_fixed(substring(pay from 10), true);
    end if;
    insert into mc.gen_template (dimension, sig, chunk, sections, light, pkt_prefix, pkt_suffix, z_prefix, z_rest, z_a_rest, z_l_rest)
    select p_dim, sig, c,
           array(select s from mc.chunk_section s where s.dimension = tdim and s.cx = 0 and s.cz = 0 order by s.sy),
           array(select l from mc.chunk_light l where l.dimension = tdim and l.cx = 0 and l.cz = 0 order by l.idx),
           substring(pkt from 1 for hdr), substring(pkt from hdr + 9),
           proto.varint(octet_length(proto.varint(octet_length(pay))) + (2 + 14 + octet_length(zr) + 4)) || proto.varint(octet_length(pay)),
           zr, mc.adler32(substring(pay from 10)), octet_length(pay) - 9
      from mc.chunk c where c.dimension = tdim and c.cx = 0 and c.cz = 0
    on conflict (dimension) do update
       set sig = excluded.sig, chunk = excluded.chunk, sections = excluded.sections, light = excluded.light,
           pkt_prefix = excluded.pkt_prefix, pkt_suffix = excluded.pkt_suffix, z_prefix = excluded.z_prefix, z_rest = excluded.z_rest,
           z_a_rest = excluded.z_a_rest, z_l_rest = excluded.z_l_rest, built_at = now();
    delete from mc.chunk where dimension = tdim;
    delete from mc.flat_layer where dimension = tdim;
    delete from mc.dimension where name = tdim;
    select * into t from mc.gen_template g where g.dimension = p_dim;
    return t;
end $$;

------------------------------------------------------------------------------------------------ batch generation
-- Creates the chunks of the list that do not exist yet (with p_replace: deletes and recreates the existing ones too).  One statement for the whole list:
-- chunk rows, section rows, light rows and the cached packets, all copied from the template.  Concurrent callers are safe (ON CONFLICT DO NOTHING:
-- a chunk is created by exactly one of them).  Returns how many chunks this call created.
create or replace function mc.generate_flat_batch(p_dim text, p_cxs int[], p_czs int[], p_replace boolean default false) returns int language plpgsql volatile as $$
declare
    t    mc.gen_template;
    n    int;
    comp boolean := mc.compression_enabled();
    pid  bytea := proto.varint(mc.chunk_packet_id());
    gen  text;
begin
    if p_cxs is null or cardinality(p_cxs) = 0 then return 0; end if;
    -- a dimension whose generator is not the flat one (mc.dimension.generator, set by the dbcraft.generator setting, sql/855): every caller of mc.generate_flat
    -- (the join, chunk streaming, the dev world reset) gets that generator's chunks; the flat path below is unchanged
    select d.generator into gen from mc.dimension d where d.name = p_dim;
    if gen is not null and gen <> 'minecraft:flat' then return mc.generate_with(gen, p_dim, p_cxs, p_czs, p_replace); end if;
    t := mc.ensure_flat_template(p_dim);
    if p_replace then
        delete from mc.chunk c using unnest(p_cxs, p_czs) u(cx, cz) where c.dimension = p_dim and c.cx = u.cx and c.cz = u.cz;
    end if;
    with want as (select distinct u.cx, u.cz from unnest(p_cxs, p_czs) u(cx, cz)),
    ins as (
        insert into mc.chunk (dimension, cx, cz, status, version, dirty, hm_dirty, hm_motion_blocking, hm_motion_blocking_no_leaves, hm_world_surface, light_ws, light_top)
        select p_dim, w.cx, w.cz, (t.chunk).status, 0, false, false,
               (t.chunk).hm_motion_blocking, (t.chunk).hm_motion_blocking_no_leaves, (t.chunk).hm_world_surface, (t.chunk).light_ws, (t.chunk).light_top
          from want w
        on conflict do nothing
        returning cx, cz),
    sec as (
        insert into mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data)
        select p_dim, i.cx, i.cz, s.sy, s.block_count, s.fluid_count, s.palette, s.bits, s.data, s.biome_palette, s.biome_bits, s.biome_data
          from ins i cross join unnest(t.sections) s),
    lig as (
        insert into mc.chunk_light (dimension, cx, cz, idx, sky_kind, sky, block_kind, block)
        select p_dim, i.cx, i.cz, l.idx, l.sky_kind, l.sky, l.block_kind, l.block
          from ins i cross join unnest(t.light) l),
    cch as (
        insert into mc.chunk_cache (dimension, cx, cz, version, packet, packet_z)
        select p_dim, i.cx, i.cz, 0, t.pkt_prefix || int4send(i.cx) || int4send(i.cz) || t.pkt_suffix,
               case when comp then t.z_prefix || '\x7801000900f6ff'::bytea || h.head || t.z_rest
                                   || substring(int8send(mc.adler32_combine(mc.adler32(h.head), t.z_a_rest, t.z_l_rest)) from 5 for 4) end
          from ins i cross join lateral (select pid || int4send(i.cx) || int4send(i.cz) as head) h
        on conflict (dimension, cx, cz) do update set version = excluded.version, packet = excluded.packet, packet_z = excluded.packet_z)
    select count(*) into n from ins;
    return n;
end $$;

create or replace function mc.generate_flat(p_dim text, p_cx int, p_cz int, p_replace boolean default false) returns boolean language plpgsql volatile as $$
begin
    return mc.generate_flat_batch(p_dim, array[p_cx], array[p_cz], p_replace) > 0;
end $$;

-- A rectangle of chunks (inclusive corners).  Returns how many were generated.
create or replace function mc.generate_flat_area(p_dim text, cx1 int, cz1 int, cx2 int, cz2 int) returns int language sql volatile as $$
  select mc.generate_flat_batch(p_dim, array_agg(x), array_agg(z)) from generate_series(least(cx1, cx2), greatest(cx1, cx2)) x, generate_series(least(cz1, cz2), greatest(cz1, cz2)) z $$;

------------------------------------------------------------------------------------------------ the registry
create table if not exists mc.generator (
    name     text primary key,                   -- minecraft:flat
    batch_fn regprocedure not null,              -- (text, int[], int[]) returns int
    note     text
);
insert into mc.generator (name, batch_fn, note)
values ('minecraft:flat', 'mc.generate_flat_batch(text, int[], int[], boolean)'::regprocedure, 'layers from mc.flat_layer, copied from a template chunk')
on conflict (name) do nothing;

alter table mc.dimension add column if not exists generator text not null default 'minecraft:flat' references mc.generator(name);

-- Call a registered generator by name: every generator takes (dimension, cxs, czs) and may take a fourth, defaulted p_replace (the flat one and dbcraft:noise do).
create or replace function mc.generate_with(p_gen text, p_dim text, p_cxs int[], p_czs int[], p_replace boolean default false) returns int language plpgsql volatile as $$
declare fn regprocedure; n int;
begin
    select g.batch_fn into fn from mc.generator g where g.name = p_gen;
    if not found then raise exception 'unknown generator %', p_gen; end if;
    execute format('select %s($1, $2, $3, $4)', fn::regproc) into n using p_dim, p_cxs, p_czs, p_replace;
    return n;
end $$;

-- Generate the chunks of a list in one dimension with that dimension's generator.  Returns how many chunks it created.
create or replace function mc.generate_batch(p_dim text, p_cxs int[], p_czs int[]) returns int language plpgsql volatile as $$
declare
    fn  regprocedure;
    n   int;
begin
    select g.batch_fn into fn from mc.dimension d join mc.generator g on g.name = d.generator where d.name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    -- every generator takes (dimension, cxs, czs); the flat one has a fourth, defaulted argument
    execute format('select %s($1, $2, $3)', fn::regproc) into n using p_dim, p_cxs, p_czs;
    return n;
end $$;
