-- dlcraft / PostgreSQL implementation, in dbcraft's style (see sql/200_world.sql, sql/330_game_players.sql, docs/TUNING.md).
-- Everything lives in schema mc.  Loading drops and recreates it, so load.sh is idempotent.
drop schema if exists mc cascade;
create schema mc;

------------------------------------------------------------------------------------------------ world
-- One row per generated chunk.  version is bumped by every edit; mc.chunk_cache.version must equal it for the cached packet to be fresh.
create table mc.chunk (
    cx      int    not null,
    cz      int    not null,
    version bigint not null default 0,
    primary key (cx, cz)
) with (fillfactor = 70);

-- One 16x16x16 section in the wire layout: palette of state ids (insertion order), bits per entry (0 | 4 | 5), packed big-endian longs.
-- Keep the data inline (never TOASTed, never compressed): byte loops over a detoasted value are quadratic (dbcraft docs/TUNING.md).
create table mc.chunk_section (
    cx          int      not null,
    cz          int      not null,
    sy          int      not null,                 -- y >> 4, -4 .. 19
    block_count smallint not null default 0,       -- non-air blocks
    palette     int[]    not null,
    bits        smallint not null default 0,
    data        bytea    not null default '\x',    -- no length prefix; empty when bits = 0
    primary key (cx, cz, sy)
) with (fillfactor = 70, toast_tuple_target = 8160);
alter table mc.chunk_section alter column data set storage main;
alter table mc.chunk_section alter column palette set storage main;

-- Finished, framed chunk packets keyed by the chunk version they were built from.  18 KB: out of line but uncompressed (nothing to gain from pglz here).
create table mc.chunk_cache (
    cx      int    not null,
    cz      int    not null,
    version bigint not null,
    packet  bytea  not null,
    primary key (cx, cz)
) with (fillfactor = 70);
alter table mc.chunk_cache alter column packet set storage external;

-- Block changes waiting for the tick.  Transient, hence unlogged; no index (the tick consumes everything, ordered by id).
create unlogged table mc.block_event (
    id        bigint generated always as identity,
    kind      text   not null,                      -- 'block' | 'fill'
    x         int    not null,
    y         int    not null,
    z         int    not null,
    old_state int    not null,                      -- -1 for a fill
    new_state int    not null,
    cnt       int    not null default 0             -- changed blocks of a fill; 0 for a block event
);

------------------------------------------------------------------------------------------------ players / tick
create table mc.game_state (
    id        int primary key default 1 check (id = 1),
    game_time bigint not null default 0
);
insert into mc.game_state default values;

-- mc.player is tuned for HOT updates exactly like dbcraft's: fillfactor 60 and NO index on any column that changes every tick
-- (position, rotation, sent_q*, last_move).  chunk_x/chunk_z change rarely, so they carry the spatial index.  eid = conn.
create table mc.player (
    eid       int primary key,
    uuid      bytea  not null,
    x         float8 not null,
    y         float8 not null,
    z         float8 not null,
    yaw       float4 not null default 0,
    pitch     float4 not null default 0,
    on_ground boolean not null default true,
    chunk_x   int    not null,
    chunk_z   int    not null,
    sent_qx   bigint not null,
    sent_qy   bigint not null,
    sent_qz   bigint not null,
    last_move bigint not null default 0
) with (fillfactor = 60);
create index player_chunk_idx on mc.player (chunk_x, chunk_z);

-- viewer can see target (both directions are stored, like dbcraft's mc.visible).  The primary key answers "targets of a viewer";
-- because both directions exist it also answers "viewers of a target".
create unlogged table mc.visible (
    viewer_eid int not null,
    target_eid int not null,
    primary key (viewer_eid, target_eid)
);

create unlogged table mc.inbox  (seq bigint generated always as identity, conn int not null, payload bytea not null);
create unlogged table mc.outbox (seq bigint generated always as identity, conn int not null, data bytea not null);

------------------------------------------------------------------------------------------------ dynamics
create table mc.sched (due bigint not null, x int not null, y int not null, z int not null);
create index sched_due_idx on mc.sched (due);

------------------------------------------------------------------------------------------------ social
create table mc.chat (
    id     bigint generated always as identity primary key,
    sender int    not null,
    msg    text   not null,
    at     bigint not null,
    tsv    tsvector generated always as (to_tsvector('simple', msg)) stored
);
create index chat_tsv_gin on mc.chat using gin (tsv);
create index chat_sender_idx on mc.chat (sender);

create table mc.inv (
    player int      not null,
    slot   smallint not null,
    item   int      not null,
    count  int      not null,
    primary key (player, slot)
) with (fillfactor = 70);
