-- Data-driven registries (biomes, dimension types, damage types, enchantments, ...) and tags, stored as readable rows.
-- Filled by tools/load_datapack.py from a vanilla server's configuration phase; encoded back to the registry_data / update_tags packets here.
--
--   ref.dp_registry     one row per registry, seq = the order the registry_data packets are sent in
--   ref.dp_entry        one row per entry, seq = position inside the registry (this is also the numeric id other packets use)
--   ref.dp_node         the entry's NBT as a tree, one row per tag: type, key, order and value
--   ref.dp_tag(_member) tags per registry, with members as names, in the order they are sent
-- Editing a biome is an UPDATE of one dp_node row; net.rebuild_config_cache() (or the statement triggers below) refresh the packets.

create table if not exists ref.dp_registry (registry text primary key, seq int not null unique);
create table if not exists ref.dp_entry (
    registry text not null references ref.dp_registry on delete cascade,
    seq      int  not null,
    name     text not null,
    has_data boolean not null default true,       -- false: the client uses its built-in copy (not used when the client knows no packs)
    primary key (registry, name),
    unique (registry, seq)
);
create table if not exists ref.dp_node (
    registry text not null,
    entry    text not null,
    node     int  not null,                       -- unique within the entry; the root is the entry's only node with parent NULL
    parent   int,
    idx      int  not null default 0,             -- position among its siblings (compound keys keep the order they are sent in)
    key      text,                                -- compound children only
    tag      smallint not null,                   -- NBT type id 1..12
    elem_tag smallint,                            -- lists: type id of the elements (0 for an empty list)
    i        bigint,                              -- byte, short, int, long
    f        float8,                              -- float (exact), double
    s        text,                                -- string
    arr      bigint[],                            -- byte/int/long arrays
    type     text generated always as (case tag when 1 then 'byte' when 2 then 'short' when 3 then 'int' when 4 then 'long' when 5 then 'float'
                                                when 6 then 'double' when 7 then 'byte_array' when 8 then 'string' when 9 then 'list'
                                                when 10 then 'compound' when 11 then 'int_array' when 12 then 'long_array' end) stored,
    primary key (registry, entry, node),
    foreign key (registry, entry) references ref.dp_entry (registry, name) on delete cascade
);
create index if not exists dp_node_children on ref.dp_node (registry, entry, parent, idx);

create table if not exists ref.dp_tag_registry (registry text primary key, seq int not null unique);
create table if not exists ref.dp_tag (
    registry text not null references ref.dp_tag_registry on delete cascade,
    tag      text not null,
    seq      int  not null,
    primary key (registry, tag),
    unique (registry, seq)
);
create table if not exists ref.dp_tag_member (
    registry text not null,
    tag      text not null,
    ord      int  not null,
    member   text not null,                       -- entry name; resolved to an id when encoding
    primary key (registry, tag, ord),
    foreign key (registry, tag) references ref.dp_tag (registry, tag) on delete cascade
);

------------------------------------------------------------------------------------------------ NBT encoder over the node tree
-- The payload of one node (no type byte, no name): what follows the header in a compound, or an element inside a list.
create or replace function nbt.encode_node(p_reg text, p_entry text, p_node int) returns bytea language plpgsql stable as $$
declare n ref.dp_node; out bytea; c record; x bigint;
begin
    select * into n from ref.dp_node where registry = p_reg and entry = p_entry and node = p_node;
    case n.tag
        when 1  then return set_byte('\x00'::bytea, 0, (n.i & 255)::int);
        when 2  then return proto.i16(n.i::int);
        when 3  then return proto.i32(n.i::int);
        when 4  then return proto.i64(n.i);
        when 5  then return proto.f32(n.f::real);
        when 6  then return proto.f64(n.f);
        when 8  then return nbt.str(n.s);
        when 7  then
            out := proto.i32(coalesce(array_length(n.arr, 1), 0));
            foreach x in array coalesce(n.arr, '{}') loop out := out || set_byte('\x00'::bytea, 0, (x & 255)::int); end loop;
            return out;
        when 11 then
            out := proto.i32(coalesce(array_length(n.arr, 1), 0));
            foreach x in array coalesce(n.arr, '{}') loop out := out || proto.i32(x::int); end loop;
            return out;
        when 12 then
            out := proto.i32(coalesce(array_length(n.arr, 1), 0));
            foreach x in array coalesce(n.arr, '{}') loop out := out || proto.i64(x); end loop;
            return out;
        when 9  then
            out := '\x'::bytea;
            for c in select node from ref.dp_node where registry = p_reg and entry = p_entry and parent = p_node order by idx loop
                out := out || nbt.encode_node(p_reg, p_entry, c.node);
            end loop;
            return proto.i8(n.elem_tag) || proto.i32((select count(*) from ref.dp_node where registry = p_reg and entry = p_entry and parent = p_node)::int) || out;
        when 10 then
            out := '\x'::bytea;
            for c in select node, key, tag from ref.dp_node where registry = p_reg and entry = p_entry and parent = p_node order by idx loop
                out := out || proto.i8(c.tag) || nbt.str(c.key) || nbt.encode_node(p_reg, p_entry, c.node);
            end loop;
            return out || '\x00'::bytea;
        else raise exception 'nbt.encode_node: no node % in %/%', p_node, p_reg, p_entry;
    end case;
end $$;

-- A whole entry as network NBT: the root's type byte followed by its payload (the root has no name).
create or replace function nbt.encode_entry(p_reg text, p_entry text) returns bytea language sql stable as $$
    select proto.i8(tag) || nbt.encode_node(p_reg, p_entry, node)
    from ref.dp_node where registry = p_reg and entry = p_entry and parent is null $$;

------------------------------------------------------------------------------------------------ packet bodies
-- registry_data: registry id, then each entry as name + optional data.
create or replace function net.registry_data_body(p_reg text) returns bytea language sql stable as $$
    select proto.string(p_reg) || proto.varint(count(*)::int)
           || coalesce(string_agg(proto.string(e.name) || proto.bool(e.has_data) || case when e.has_data then nbt.encode_entry(e.registry, e.name) else '\x'::bytea end,
                                  ''::bytea order by e.seq), '\x'::bytea)
    from ref.dp_entry e where e.registry = p_reg $$;

-- update_tags: for each registry (in order) its tags, each with the ids of its members.
create or replace function net.tag_member_id(p_reg text, p_member text) returns int language sql stable as $$
    select coalesce((select e.seq from ref.dp_entry e where e.registry = p_reg and e.name = p_member),
                    (select g.protocol_id from ref.registry g where g.registry = p_reg and g.name = p_member),
                    proto.bad('unknown tag member ' || p_reg || ' ' || p_member)::int) $$;

create or replace function net.update_tags_body() returns bytea language sql stable as $$
    select proto.varint(count(*)::int) || coalesce(string_agg(
        proto.string(r.registry) || proto.varint((select count(*)::int from ref.dp_tag t where t.registry = r.registry))
        || coalesce((select string_agg(
               proto.string(t.tag) || proto.varint((select count(*)::int from ref.dp_tag_member m where m.registry = t.registry and m.tag = t.tag))
               || coalesce((select string_agg(proto.varint(net.tag_member_id(m.registry, m.member)), ''::bytea order by m.ord)
                            from ref.dp_tag_member m where m.registry = t.registry and m.tag = t.tag), '\x'::bytea),
               ''::bytea order by t.seq) from ref.dp_tag t where t.registry = r.registry), '\x'::bytea),
        ''::bytea order by r.seq), '\x'::bytea)
    from ref.dp_tag_registry r $$;

------------------------------------------------------------------------------------------------ cache of finished configuration packets
-- The configuration packets are identical for every client, so they are built once.  Empty cache = rebuilt on next use.
create unlogged table if not exists net.config_cache (seq int primary key, packet text not null, body bytea not null);

create or replace function net.rebuild_config_cache() returns int language plpgsql as $$
declare n int;
begin
    delete from net.config_cache;
    insert into net.config_cache (seq, packet, body)
    select row_number() over (order by r.seq)::int, 'minecraft:registry_data', net.registry_data_body(r.registry) from ref.dp_registry r;
    get diagnostics n = row_count;
    insert into net.config_cache (seq, packet, body) values (n + 1, 'minecraft:update_tags', net.update_tags_body());
    return n + 1;
end $$;

create or replace function net.invalidate_config_cache() returns trigger language plpgsql as $$
begin delete from net.config_cache; return null; end $$;
do $$
declare t text;
begin
    foreach t in array array['dp_registry', 'dp_entry', 'dp_node', 'dp_tag_registry', 'dp_tag', 'dp_tag_member'] loop
        execute format('drop trigger if exists invalidate_config_cache on ref.%I', t);
        execute format('create trigger invalidate_config_cache after insert or update or delete on ref.%I for each statement execute function net.invalidate_config_cache()', t);
    end loop;
end $$;
