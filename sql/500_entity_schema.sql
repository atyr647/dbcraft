-- Entity simulation PROTOTYPE (opt-in; nothing here is called by the server tick yet: mc.entity_tick() is the entry point, see docs/ENTITY.md).
--
-- An entity is a row.  Fields that change every tick (position, velocity, on_ground, bookkeeping) are kept UNINDEXED so updates stay HOT;
-- the only secondary index is the chunk cell (cx, cz), which changes only when an entity crosses a chunk border.
-- Time-dependent values are derived from born_tick instead of being updated every tick: age = tick - born_tick, pickup allowed when tick >= pickup_at.
create table if not exists mc.entity_type_param (
    type            text primary key,                -- minecraft:item
    kind            text not null check (kind in ('item', 'mob')),
    width           float8 not null,
    height          float8 not null,
    gravity         float8 not null,                 -- blocks/tick^2 (ItemEntity: 0.04, from the bytecode; LivingEntity: 0.08)
    update_interval int not null,                    -- tracker: position check every N ticks (EntityType.updateInterval: the Builder default is 3, items 20, players 2; read from the bytecode)
    track_delta     boolean not null,                -- tracker also sends set_entity_motion when the velocity changed
    linear_delta    boolean not null,                -- true: VecDelta.Linear (flags 0/1 + 3 shorts, as the captured item packets); false: Stepped (ticks + 3 shorts)
    tracking_chunks int not null,                    -- clientTrackingRange in chunks (read from the 26.3 bytecode, EntityTypes + EntityType$Builder: item 6, cow 10, zombie 8; the Builder default is 5; docs/PERF-ENTITY.md, tests/sql/551)
    max_age         int,                             -- items despawn at 6000 ticks
    walk_speed      float8,                          -- mobs: blocks per tick while walking (APPROXIMATE, not vanilla's attribute model)
    can_chase       boolean not null default false
);
insert into mc.entity_type_param (type, kind, width, height, gravity, update_interval, track_delta, linear_delta, tracking_chunks, max_age, walk_speed, can_chase) values
    ('minecraft:item',   'item', 0.25, 0.25, 0.04, 20, true,  true,  6,  6000, null, false),
    ('minecraft:cow',    'mob',  0.9,  1.4,  0.08, 3,  false, false, 10, null, 0.10, false),
    ('minecraft:zombie', 'mob',  0.6,  1.95, 0.08, 3,  false, false, 8,  null, 0.13, true)
on conflict (type) do nothing;

create table if not exists mc.entity (
    id          int primary key,                     -- the network entity id, from the same sequence as players (mc.entity_id_seq)
    uuid        uuid not null,
    type        text not null references mc.entity_type_param(type),
    type_id     int  not null,                       -- registry id of minecraft:entity_type (cached for packet building)
    dimension   text not null default 'minecraft:overworld',
    x float8 not null, y float8 not null, z float8 not null,
    vx float8 not null default 0, vy float8 not null default 0, vz float8 not null default 0,
    yaw real not null default 0, pitch real not null default 0,
    on_ground   boolean not null default false,
    born_tick   bigint not null,                     -- game time at spawn: age = tick - born_tick
    pickup_at   bigint not null default 0,           -- items: first tick at which a player may pick it up
    phys_tick   bigint not null default 0,           -- last tick the physics step processed this row (sleeping rows are skipped: gravity accumulates lazily)
    deep_sleep  boolean not null default false,      -- at rest and supported: skipped entirely until a block changes nearby (vanilla wakes such items every 4th tick; same result)
    gx float8 not null default 0, gz float8 not null default 0,        -- mobs: desired horizontal velocity of the current goal
    goal_until  bigint not null default 0,           -- mobs: tick at which the AI picks a new goal
    cx int not null, cz int not null,                -- chunk cell of (x, z): the only indexed hot-ish column
    -- what the viewers were last told (their shared delta base, like vanilla's ServerEntity)
    sent_qx bigint not null default 0, sent_qy bigint not null default 0, sent_qz bigint not null default 0,
    sent_vx float8 not null default 0, sent_vy float8 not null default 0, sent_vz float8 not null default 0,
    sent_yaw real not null default 0, sent_pitch real not null default 0, sent_on_ground boolean not null default false,
    last_sent_tick bigint not null default 0,
    data        jsonb not null default '{}'          -- type specific: items {"item":"minecraft:stone","count":3}
) with (fillfactor = 50);
create index if not exists entity_cell_idx on mc.entity (cx, cz);
-- the awake entities only: the physics step reads this index, so entities in deep sleep cost nothing per tick.  deep_sleep is in the index predicate, so only a row that
-- falls asleep or wakes up pays for an index change; every other update of an awake row stays HOT.
create index if not exists entity_awake_idx on mc.entity (id) where not deep_sleep;

-- Collision classes of block names.  APPROXIMATION: a block is either a full solid cube or has no collision; slabs, stairs, fences, doors, ... count as full cubes.
-- Friction is the block's slipperiness (0.6 default).
create table if not exists mc.block_class (
    name     text primary key,                       -- minecraft:stone (no properties)
    solid    boolean not null,
    friction real not null default 0.6
);
-- Filled from ref.block.  The standard order is migrate THEN load the reference data (tools/load_reports.py), when ref.block is still empty at migration time:
-- tools/load_reports.py therefore calls mc.refresh_block_class() after loading (found by the isolated test runner: entities fell through the floor on a fresh install).
create or replace function mc.refresh_block_class() returns int language plpgsql volatile as $fn$
declare n int;
begin
  insert into mc.block_class (name, solid, friction)
  select b.name,
         not (b.name ~ '^minecraft:(air|cave_air|void_air|water|lava|bubble_column|light|structure_void|short_grass|tall_grass|fern|large_fern|dead_bush|seagrass|tall_seagrass|kelp|kelp_plant|vine|glow_lichen|sculk_vein|hanging_roots|fire|soul_fire|snow|rail|powered_rail|detector_rail|activator_rail|redstone_wire|tripwire|tripwire_hook|lever|string|cobweb_unsolid|dandelion|poppy|blue_orchid|allium|azure_bluet|oxeye_daisy|cornflower|lily_of_the_valley|wither_rose|sunflower|lilac|rose_bush|peony|torchflower|pitcher_plant|brown_mushroom|red_mushroom|crimson_roots|warped_roots|nether_sprouts|spore_blossom|sweet_berry_bush|wheat|carrots|potatoes|beetroots|nether_wart|sugar_cane|bamboo_sapling|torch|wall_torch|soul_torch|soul_wall_torch|redstone_torch|redstone_wall_torch|end_rod|ladder|cobweb|scaffolding_unsolid)$'
              or b.name ~ '(_sapling|_carpet|_sign|_wall_sign|_hanging_sign|_banner|_wall_banner|_button|_pressure_plate|_tulip|_orchid|_mushroom_unsolid|_propagule|_pressure_plate)$'),
         case when b.name in ('minecraft:ice', 'minecraft:packed_ice', 'minecraft:frosted_ice') then 0.98::real
              when b.name = 'minecraft:blue_ice' then 0.989::real
              when b.name = 'minecraft:slime_block' then 0.8::real
              else 0.6::real end
  from ref.block b
  on conflict (name) do nothing;
  get diagnostics n = row_count;
  return n;
end $fn$;
select mc.refresh_block_class();

-- Solidity of every 16x16x16 section as a bitmask (bit i = entry i of the section, in wire order (y*16+z)*16+x; PostgreSQL's get_bit numbers bits LSB-first within a byte,
-- which is exactly the order the mask is built in).  A cache: rebuilt lazily when mc.chunk.version moved.  solid_cnt = 0 means "all passable": entities skip the cell tests.
create unlogged table if not exists mc.solid_mask (
    dimension text not null, cx int not null, cz int not null, sy int not null,
    ver       bigint not null,                       -- mc.chunk.version at build time (-1: the chunk/section does not exist)
    solid_cnt smallint not null,
    slippery  boolean not null default false,        -- some palette entry has friction <> 0.6: friction needs the slow path
    mask      bytea not null,
    primary key (dimension, cx, cz, sy)
) with (fillfactor = 90);

-- Which players see which chunk cells (the entity tracker's interest relation): conn_id sees every entity whose chunk is within `r` chunks of (cx, cz) (Chebyshev).
-- Maintained incrementally: only players that crossed a chunk border since the last refresh are touched.
create unlogged table if not exists mc.entity_viewer_cell (
    conn_id int primary key, cx int not null, cz int not null, r int not null
);
create unlogged table if not exists mc.entity_cell_viewer (
    cx int not null, cz int not null, conn_id int not null,
    primary key (cx, cz, conn_id)
);
create index if not exists entity_cell_viewer_conn_idx on mc.entity_cell_viewer (conn_id);

-- Per-entity packets of the last entity tick (kept for tests and measurements; truncated by the tick every second like the other queues, not per tick).
create unlogged table if not exists mc.entity_tick_log (
    tick bigint primary key, awake int, moved int, sent int, packets int, ms_physics float8, ms_ai float8, ms_tracker float8, ms_pickup float8, ms_total float8
);

------------------------------------------------------------------------------------------------ LpVec3 (low-precision velocity vector)
-- net.minecraft.network.LpVec3, read from the bytecode: 15-bit components, 2 scale bits + a continuation flag, offsets 3/18/33, abs min 3.051944088384301E-5.
-- Zero (all components below the minimum) is one byte 0x00.
create or replace function proto.lpvec3(x float8, y float8, z float8) returns bytea language plpgsql immutable parallel safe as $$
declare mx float8; scale bigint; lowest bigint; packed bigint; sx float8; sy float8; sz float8;
begin
    sx := least(greatest(case when x = x then x else 0 end, -1.7179869183E10), 1.7179869183E10);        -- sanitize: NaN -> 0, clamp
    sy := least(greatest(case when y = y then y else 0 end, -1.7179869183E10), 1.7179869183E10);
    sz := least(greatest(case when z = z then z else 0 end, -1.7179869183E10), 1.7179869183E10);
    mx := greatest(abs(sx), abs(sy), abs(sz));
    if mx < 3.051944088384301E-5 then return '\x00'::bytea; end if;
    scale := ceil(mx)::bigint;
    lowest := case when (scale & 3) <> scale then (scale & 3) | 4 else scale end;
    packed := lowest
           | ((floor((sx / scale * 0.5 + 0.5) * 32766.0 + 0.5)::bigint & 32767) << 3)
           | ((floor((sy / scale * 0.5 + 0.5) * 32766.0 + 0.5)::bigint & 32767) << 18)
           | ((floor((sz / scale * 0.5 + 0.5) * 32766.0 + 0.5)::bigint & 32767) << 33);
    return set_byte(set_byte('\x0000'::bytea, 0, (packed & 255)::int), 1, ((packed >> 8) & 255)::int)
           || int4send((((packed >> 16) & 4294967295) - case when ((packed >> 16) & 4294967295) >= 2147483648 then 4294967296 else 0 end)::int)
           || case when (scale & 3) <> scale then proto.varint((scale >> 2)::int) else '\x'::bytea end;
end $$;

-- The reader (for tests against captured packets): returns the vector and the offset after it.
create or replace function proto.lpvec3_read(b bytea, off int default 0, out x float8, out y float8, out z float8, out nxt int) language plpgsql immutable parallel safe as $$
declare b0 int; b1 int; hi bigint; packed bigint; scale bigint; rest record;
begin
    b0 := get_byte(b, off);
    if b0 = 0 then x := 0; y := 0; z := 0; nxt := off + 1; return; end if;
    b1 := get_byte(b, off + 1);
    hi := (get_byte(b, off + 2)::bigint << 24) | (get_byte(b, off + 3)::bigint << 16) | (get_byte(b, off + 4)::bigint << 8) | get_byte(b, off + 5)::bigint;
    packed := (hi << 16) | (b1::bigint << 8) | b0::bigint;
    scale := (b0 & 3)::bigint;
    nxt := off + 6;
    if (b0 & 4) <> 0 then
        select val, nxt2 into rest from (select r.val::bigint & 4294967295 as val, r.nxt as nxt2 from proto.varint_read(b, off + 6) r) q;
        scale := scale | (rest.val << 2); nxt := rest.nxt2;
    end if;
    x := least((packed >> 3) & 32767, 32766) * 2.0 / 32766.0 - 1.0; x := x * scale;
    y := least((packed >> 18) & 32767, 32766) * 2.0 / 32766.0 - 1.0; y := y * scale;
    z := least((packed >> 33) & 32767, 32766) * 2.0 / 32766.0 - 1.0; z := z * scale;
end $$;

-- DIRTY-DRIVEN viewer refresh (docs/WHY-MOBS-COST.md section 10): the interest sets (mc.entity_viewer_cell, mc.entity_cell_viewer) only change when a player joins, leaves or enters another
-- chunk, or when the view distance changes.  Row triggers on mc.player note those events here (a row per connection); mc.entity_viewers_refresh (sql/541) takes the notes and looks at THOSE players only,
-- instead of reading every player and every interest row on every tick.  (Unlogged, like the interest sets: after a crash both are empty and the view-distance check below refills them.)
create unlogged table if not exists mc.entity_view_dirty (conn_id int primary key);
create or replace function mc.entity_view_dirty_mark() returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        if old.conn_id is not null then insert into mc.entity_view_dirty values (old.conn_id) on conflict do nothing; end if;
        return old;
    end if;
    if new.conn_id is not null then insert into mc.entity_view_dirty values (new.conn_id) on conflict do nothing; end if;
    if tg_op = 'UPDATE' and old.conn_id is not null and old.conn_id is distinct from new.conn_id then insert into mc.entity_view_dirty values (old.conn_id) on conflict do nothing; end if;
    return new;
end $$;
drop trigger if exists entity_view_dirty_ins on mc.player;
drop trigger if exists entity_view_dirty_upd on mc.player;
drop trigger if exists entity_view_dirty_del on mc.player;
create trigger entity_view_dirty_ins after insert on mc.player for each row execute function mc.entity_view_dirty_mark();
create trigger entity_view_dirty_upd after update of conn_id, chunk_x, chunk_z on mc.player for each row
    when (old.conn_id is distinct from new.conn_id or old.chunk_x is distinct from new.chunk_x or old.chunk_z is distinct from new.chunk_z) execute function mc.entity_view_dirty_mark();
create trigger entity_view_dirty_del after delete on mc.player for each row execute function mc.entity_view_dirty_mark();
