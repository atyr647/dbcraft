-- Reference data.  Filled by tools/load_reports.py from the data generator's reports; empty after migration.
create table if not exists ref.registry (
    registry    text not null,          -- e.g. minecraft:item
    name        text not null,          -- e.g. minecraft:stone
    protocol_id int  not null,
    primary key (registry, name),
    unique (registry, protocol_id)
);

create table if not exists ref.block (
    name          text primary key,     -- minecraft:oak_log
    default_state int  not null,
    properties    jsonb not null default '{}'   -- property -> allowed values, in definition order
);

create table if not exists ref.block_state (
    state_id   int  primary key,        -- the id used on the wire
    block      text not null references ref.block(name),
    properties jsonb not null default '{}',
    is_default boolean not null,
    name       text not null unique     -- readable: minecraft:oak_log[axis=y]; plain block name when it has no properties
);
create index if not exists block_state_block_idx on ref.block_state(block);

create table if not exists ref.packet (
    state       text not null,          -- handshake | status | login | configuration | play
    direction   text not null check (direction in ('clientbound','serverbound')),
    name        text not null,          -- minecraft:keep_alive
    protocol_id int  not null,
    primary key (state, direction, name),
    unique (state, direction, protocol_id)
);

create or replace view ref.item as
    select name, protocol_id as id from ref.registry where registry = 'minecraft:item';
