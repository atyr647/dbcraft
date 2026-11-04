-- World dynamics, part 1: reference data, the scheduled-tick queue and the settings.  docs/WORLD-DYNAMICS.md is the design; the other files are
--   881  the world cache and the engine (one PL/pgSQL function that runs fluid, block and random ticks and the neighbour updates they cause)
--   882  the neighbour-update entry points (the trigger on mc.block_event) and the tick step the game loop calls
--
-- The data in mc.dyn_state / mc.dyn_shape / mc.dyn_occlude is DERIVED FROM THE VANILLA JAR (tools/gen_dynamics.sh runs tools/java/DynDump.java, tools/load_dynamics.py loads
-- the result); it is not in the repository.  Without it mc.dyn_ready() is false and every dynamics entry point returns at once: a database without the data behaves as before.

-- ---------------------------------------------------------------------------------------------------------------------------------------- reference data
-- one row per block state, keyed like ref.block_state (sid = state id)
create table if not exists mc.dyn_state (
    sid           int primary key,
    name          text not null,                       -- the state name the world stores: minecraft:oak_log[axis=x]
    block         text not null,
    chain         text not null,                       -- Java class chain, most specific first ('GrassBlock>SpreadingSnowyBlock>SnowyBlock'); '' for a plain Block
    rtick         boolean not null,                    -- BlockState.isRandomlyTicking()
    air           boolean not null,
    solid         boolean not null,                    -- BlockState.isSolid()   (FlowingFluid.getNewLiquid asks it of the block below)
    occludes      boolean not null,
    blocks_motion boolean not null,
    fluid         text not null default '',            -- '' | water | lava   (the state's FluidState: waterlogged blocks and kelp have water)
    famount       smallint not null default 0,         -- FluidState.getAmount(): 8 source, 7..1 flowing, 8 with falling = true for the falling flowing state
    ffall         boolean not null default false,
    wl            boolean not null default false,      -- the block is a SimpleWaterloggedBlock
    coll          int not null default -1,             -- id of the collision shape (mc.dyn_shape)
    sf            text not null default '000000',      -- isFaceSturdy(dir, FULL) for DOWN UP NORTH SOUTH WEST EAST
    sc            text not null default '000000',      -- ... CENTER
    sr            text not null default '000000',      -- ... RIGID
    lbc           boolean not null default false,      -- the block is a LiquidBlockContainer
    repl          boolean not null default false,      -- BlockState.canBeReplaced()
    lightd        smallint not null default 0          -- BlockState.getLightDampening() (15 for an opaque cube)
);
alter table mc.dyn_state add column if not exists lightd smallint not null default 0;
alter table mc.dyn_state add column if not exists react boolean not null default false;       -- a change next to this state can make it react (flag mask 4 | 8 | 4096 | 65536 | 262144, filled by mc.dyn_rebuild)
alter table mc.dyn_state add column if not exists tickc boolean not null default false;       -- a class of random tick this engine implements (grass, crops, farmland, saplings)
create unique index if not exists dyn_state_name_key on mc.dyn_state (name);
create index if not exists dyn_state_block_idx on mc.dyn_state (block);
create table if not exists mc.dyn_shape (id int primary key, kind smallint not null, aabbs text not null);                 -- kind 0 empty, 1 full block, 2 other
create table if not exists mc.dyn_occlude (from_shape smallint not null, to_shape smallint not null, dir smallint not null, primary key (from_shape, to_shape, dir));

-- The arrays the engine reads (one detoast each per step, index = state id + 1).  mc.dyn_rebuild() (sql/886) fills it from the tables above and the block tags: mc.dyn_rebuild_base()
-- here, the support rules there.
--   flags    bit set per state, see F_* below
--   famt     fluid amount 0..9 (9 never used), as FluidState.getAmount
--   coll     collision shape id
--   skind    shape id + 1 -> kind
--   occ      bit ((from * nshape + to) * 6 + dir): Shapes.mergedFaceOccludes(from, to, dir) for two partial shapes
--   bid      block ordinal per state (mc.dyn_block)
-- The state id n (one past the last real state) is a barrier: solid, full block, never replaceable.  The engine reads unloaded chunks as that.
create table if not exists mc.dyn_block (bid int primary key, name text not null unique);
create table if not exists mc.dyn_vec (
    id int primary key check (id = 1),
    n int not null, nshape int not null,
    flags int4[] not null, famt int2[] not null, coll int4[] not null, skind int2[] not null, bid int4[] not null,
    occ bytea not null,
    k int4[] not null default '{}'          -- constants: see mc.dyn_rebuild
);

alter table mc.dyn_vec add column if not exists k int4[] not null default '{}';
alter table mc.dyn_vec add column if not exists lightd int2[] not null default '{}';        -- per state: BlockState.getLightDampening()
alter table mc.dyn_vec add column if not exists nextp int4[] not null default '{}';        -- per state: the state with the next `age` (crops) or `stage` (saplings), -1 if none
alter table mc.dyn_vec add column if not exists rule int4[] not null default '{}';        -- per state: the support rule, see sql/886
alter table mc.dyn_vec add column if not exists tagbits int8[] not null default '{}';     -- per state: membership of the block tags the rules use, see sql/886
alter table mc.dyn_vec add column if not exists wlt int4[] not null default '{}';        -- per state: the state id of the waterlogged = true variant (-1: none)
alter table mc.dyn_vec add column if not exists sturdy int4[] not null default '{}';     -- per state: bits 0-5 isFaceSturdy FULL, 6-11 CENTER, 12-17 RIGID for DOWN UP NORTH SOUTH WEST EAST
-- The arrays are read whole by every engine run and every list build: stored uncompressed (a pglz pass over 140-280 KB costs a millisecond or more each time they are detoasted).
alter table mc.dyn_vec alter column flags set storage external, alter column famt set storage external, alter column coll set storage external, alter column skind set storage external,
                       alter column bid set storage external, alter column occ set storage external, alter column k set storage external, alter column wlt set storage external,
                       alter column sturdy set storage external, alter column lightd set storage external, alter column nextp set storage external, alter column rule set storage external,
                       alter column tagbits set storage external;
-- k[]: 1 air, 2 void_air, 3 cobblestone, 4 obsidian, 5 stone, 6 basalt, 7 .. 22 water[level = 0 .. 15], 23 .. 38 lava[level = 0 .. 15], 39 soul_soil, 40 blue_ice, 41 dirt,
--      42 .. 49 farmland[moisture = 0 .. 7]
-- F_* flags (powers of two; the engine uses the literal numbers, keep them in sync)
--       1 AIR            2 SOLID (BlockState.isSolid)        4 LIQUID (a LiquidBlock: water, lava)      8 WATER fluid state      16 LAVA fluid state
--      32 SOURCE (fluid source)    64 FALLING flowing         128 WATERLOGGABLE (SimpleWaterloggedBlock) 256 LiquidBlockContainer 512 HOLD (canHoldAnyFluid)
--    1024 RTICK       2048 REPLACEABLE     4096 GRAVITY (a FallingBlock)  8192 BLOCKS_MOTION  16384 BARRIER (unloaded)  32768 FIRE (tag)
--   65536 CONCRETE POWDER (turns into concrete next to water)   131072 lower half (a door or a tall plant)   262144 has a support rule (sql/886)
--  524288 SPREADING (grass block, mycelium)  1048576 CROP  2097152 FARMLAND  4194304 SAPLING (random-tick behaviours of sql/887)
create or replace function mc.dyn_ready() returns boolean language sql stable as $$ select exists (select 1 from mc.dyn_vec) $$;

create or replace function mc.dyn_rebuild_base() returns void language plpgsql volatile as $$
declare
    n     int;
    ns    int;
    washed text[];
    fire   text[];
begin
    select coalesce(max(sid) + 1, 0) into n from mc.dyn_state;
    if n = 0 then delete from mc.dyn_vec; return; end if;
    select coalesce(max(id) + 1, 0) into ns from mc.dyn_shape;
    select array_agg(member) into washed from ref.dp_tag_member where registry = 'minecraft:block' and tag = 'minecraft:washed_away_by_fluids';
    select array_agg(member) into fire   from ref.dp_tag_member where registry = 'minecraft:block' and tag = 'minecraft:fire';
    delete from mc.dyn_block;
    insert into mc.dyn_block (bid, name) select (row_number() over (order by b))::int - 1, b from (select distinct block b from mc.dyn_state) q;
    delete from mc.dyn_vec;
    insert into mc.dyn_vec (id, n, nshape, flags, famt, coll, skind, bid, occ, k, wlt, sturdy, lightd)
    select 1, n, ns,
        (select array_agg(f order by s) || array[2 | 8192 | 16384]
           from (select s.sid as s,
                        (case when s.air then 1 else 0 end) | (case when s.solid then 2 else 0 end) | (case when s.block in ('minecraft:water', 'minecraft:lava') then 4 else 0 end)
                        | (case when s.fluid = 'water' then 8 else 0 end) | (case when s.fluid = 'lava' then 16 else 0 end)
                        | (case when s.fluid <> '' and s.famount = 8 and not s.ffall then 32 else 0 end) | (case when s.fluid <> '' and s.ffall then 64 else 0 end)
                        | (case when s.wl then 128 else 0 end) | (case when s.lbc then 256 else 0 end)
                        | (case when s.lbc or s.block = any (washed) then 512 else 0 end)
                        | (case when s.rtick then 1024 else 0 end) | (case when s.repl then 2048 else 0 end)
                        | (case when s.chain like '%FallingBlock%' then 4096 else 0 end) | (case when s.blocks_motion then 8192 else 0 end)
                        | (case when s.block = any (fire) then 32768 else 0 end) | (case when s.chain like 'ConcretePowderBlock%' then 65536 else 0 end) as f
                   from mc.dyn_state s) q),
        (select array_agg(s.famount order by s.sid) || array[0::smallint] from mc.dyn_state s),
        (select array_agg(s.coll order by s.sid) || array[(select id from mc.dyn_shape where kind = 1 limit 1)] from mc.dyn_state s),
        (select array_agg(h.kind order by h.id) from mc.dyn_shape h),
        (select array_agg(b.bid order by s.sid) || array[-1] from mc.dyn_state s join mc.dyn_block b on b.name = s.block),
        (select decode(string_agg(lpad(to_hex(bits), 2, '0'), '' order by bytepos), 'hex')
           from (select bytepos, sum(((case when o.from_shape is null then 0 else 1 end)::int << (bit))) as bits
                   from (select bytepos, bit, ((bytepos * 8 + bit) / 6) as pair, ((bytepos * 8 + bit) % 6) as d
                           from generate_series(0, (ns * ns * 6 + 7) / 8 - 1) bytepos, generate_series(0, 7) bit) x
                   left join mc.dyn_occlude o on o.from_shape = x.pair / ns and o.to_shape = x.pair % ns and o.dir = x.d
                  group by bytepos) b2),
        (select array[(select default_state from ref.block where name = 'minecraft:air'), (select default_state from ref.block where name = 'minecraft:void_air'),
                      (select default_state from ref.block where name = 'minecraft:cobblestone'), (select default_state from ref.block where name = 'minecraft:obsidian'),
                      (select default_state from ref.block where name = 'minecraft:stone'), (select default_state from ref.block where name = 'minecraft:basalt')]
                || array(select (select sid from mc.dyn_state where name = 'minecraft:water[level=' || l || ']') from generate_series(0, 15) l order by l)
                || array(select (select sid from mc.dyn_state where name = 'minecraft:lava[level=' || l || ']') from generate_series(0, 15) l order by l)
                || array[(select default_state from ref.block where name = 'minecraft:soul_soil'), (select default_state from ref.block where name = 'minecraft:blue_ice'), (select default_state from ref.block where name = 'minecraft:dirt')]
                || array(select (select sid from mc.dyn_state where name = 'minecraft:farmland[moisture=' || l || ']') from generate_series(0, 7) l order by l) || array[(select sid from mc.dyn_state where name = 'minecraft:snow[layers=1]')]),
        (select array_agg(coalesce(w.sid, -1) order by s.sid) || array[-1] from mc.dyn_state s left join mc.dyn_state w on s.wl and w.name = replace(s.name, 'waterlogged=false', 'waterlogged=true') and s.name like '%waterlogged=false%'),
        (select array_agg((select sum(case when substr(s.sf, i, 1) = '1' then 1 << (i - 1) else 0 end) + sum(case when substr(s.sc, i, 1) = '1' then 1 << (i + 5) else 0 end) + sum(case when substr(s.sr, i, 1) = '1' then 1 << (i + 11) else 0 end)
                             from generate_series(1, 6) i) order by s.sid) || array[63] from mc.dyn_state s),
        (select array_agg(s.lightd order by s.sid) || array[15::int2] from mc.dyn_state s);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------------------- the scheduled-tick queue
-- One row per pending tick, as vanilla's LevelTicks/LevelChunkTicks hold them (ScheduledTick: type, pos, triggerTick, priority, subTickOrder).
--   kind  'b' block tick (type = the block's name), 'f' fluid tick (type = 'water' | 'lava'), 'l' the landing of a falling block (type = the state name, x y z = the landing cell)
--   due   the game tick from which it may run (vanilla: triggerTick = game time when scheduled + delay)
--   prio  vanilla's TickPriority ordinal - 3 (EXTREMELY_HIGH -3 ... NORMAL 0 ... EXTREMELY_LOW 3)
--   seq   subTickOrder: a global counter, so ticks scheduled earlier run first within the same priority
-- The primary key is vanilla's uniqueness rule: scheduling (type, position) again while it is pending is ignored.  Ticks of chunks no player simulates stay queued
-- (vanilla keeps them in the loaded chunk, and the saved delay of an UNloaded chunk does not count down; dbcraft never unloads chunks, so a tick that became due while
-- nobody was near runs as soon as a player comes into range).
create sequence if not exists mc.block_tick_seq;
create table if not exists mc.block_tick (
    dimension text not null default 'minecraft:overworld',
    x int not null, y int not null, z int not null,
    kind "char" not null,
    type text not null,
    due bigint not null,
    prio smallint not null default 0,
    seq bigint not null default nextval('mc.block_tick_seq'),
    state text,                                                    -- kind 'l': the falling block's state (type holds the same); null otherwise
    primary key (dimension, x, y, z, kind, type)
);
create index if not exists block_tick_due_idx on mc.block_tick (kind, due);
create index if not exists block_tick_chunk_idx on mc.block_tick (dimension, (x >> 4), (z >> 4));

-- block changes made by the entity phase (falling blocks landing): announced by the next tick's broadcast (mc.dyn_step puts them back into mc.block_event)
create table if not exists mc.dyn_late_event (
    seq bigint generated always as identity primary key,
    kind text not null, dimension text not null, x int not null, y int not null, z int not null, old_state text not null, new_state text not null, cells bytea
);

-- random ticks (sql/887): the chunks whose list of randomly ticking cells that can change something must be rebuilt (a block changed in or next to them, or they are new)
drop table if exists mc.dyn_rt_dirty;                              -- derived data: sql/887 queues every chunk again
create sequence if not exists mc.dyn_rt_dirty_seq;
create table mc.dyn_rt_dirty (dimension text not null, cx int not null, cz int not null, seq bigint not null default nextval('mc.dyn_rt_dirty_seq'), mt bigint not null default 0, primary key (dimension, cx, cz));   -- mt: game time of the last change
create index dyn_rt_dirty_seq_idx on mc.dyn_rt_dirty (dimension, seq);          -- the newest change is rebuilt first

-- ---------------------------------------------------------------------------------------------------------------------------------------- settings
insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.dynamics', 'on', 'on', 'dbcraft: world dynamics (scheduled ticks, fluids, falling blocks, neighbour updates, random ticks); off makes every dynamics entry point return at once'),
    ('dbcraft.dynamics-max-ticks', '65536', '65536', 'dbcraft: most scheduled block ticks, and most fluid ticks, run in one tick; the rest stay queued for the following ticks.  65,536 is vanilla''s limit (ServerLevel.tick passes it to LevelTicks.tick, whose drain stops there and leaves the rest queued)'),
    ('dbcraft.dynamics-dimensions', 'minecraft:overworld,minecraft:the_nether,minecraft:the_end', 'minecraft:overworld,minecraft:the_nether,minecraft:the_end', 'dbcraft: comma-separated dimensions in which block edits trigger world dynamics (other dimensions, such as the tests'' dbcraft:a, store blocks without reacting)')
on conflict (key) do nothing;

create or replace function mc.dyn_enabled() returns boolean language plpgsql stable as $$
begin return coalesce((select value from mc.server_property where key = 'dbcraft.dynamics') <> 'off', true) and exists (select 1 from mc.dyn_vec); end $$;

-- game rules by their vanilla names ('minecraft:random_tick_speed'); the table is empty until a rule is set, defaults are vanilla's
create or replace function mc.rule_int(p_name text, p_default int) returns int language sql stable as $$
  select coalesce((select value::int from mc.game_rule where name = 'minecraft:' || p_name), p_default) $$;
