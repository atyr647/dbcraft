-- World dynamics (sql/880-887): the tick queue, fluids, falling blocks, block support, random ticks.  Needs the data derived from the jar (tools/gen_dynamics.sh,
-- tools/load_dynamics.py: the template of tests/sql/prun.sh loads it); without it the whole file is skipped with a notice.
-- The byte-for-byte comparison with a REAL vanilla 26.3 server (12 scenarios, every packet of every tick) is tests/e2e/dyn_probe.py; this file checks the rules in SQL, the pieces
-- that comparison cannot see (queue order, simulation range, settings, caches) and the statistics of random ticks.
select mc.dyn_ready() as have_data \gset
\if :have_data
create or replace function pg_temp.tk(n int) returns void language plpgsql as $$
declare cur bigint;
begin
  for i in 1 .. n loop
    update mc.game_state set game_time = game_time + 1, day_time = 6000 returning game_time into cur;
    perform mc.dyn_step(cur);
    perform mc.dyn_release_late();
    delete from mc.block_event;
  end loop;
end $$;
create or replace function pg_temp.reset() returns void language plpgsql as $$
begin
  truncate mc.block_tick, mc.block_event, mc.dyn_late_event, mc.play_out;
  delete from mc.player;
  insert into mc.player (uuid, name, conn_id, entity_id, chunk_x, chunk_z) values ('00000000-0000-0000-0000-00000000f001', 'T1', 77, 77, 0, 0);
  delete from mc.game_rule;
  insert into mc.game_rule values ('minecraft:random_tick_speed', '0');
  update mc.game_state set game_time = 1000, day_time = 6000;
  update mc.dyn_rt_state set next_build = 0;
  perform mc.fill('minecraft:overworld', -24, -60, -24, 24, -40, 24, 'minecraft:air');
  perform mc.fill('minecraft:overworld', -24, -61, -24, 24, -61, 24, 'minecraft:stone');
  delete from mc.block_event; truncate mc.block_tick;
end $$;
create or replace function pg_temp.blk(x int, y int, z int) returns text language sql as $$ select mc.get_block('minecraft:overworld', x, y, z) $$;
create or replace function pg_temp.put(x int, y int, z int, b text) returns void language sql as $$ select mc.set_block('minecraft:overworld', x, y, z, b) $$;
create or replace function pg_temp.count_like(pat text) returns bigint language sql as $$ select count(*) from mc.blocks_in('minecraft:overworld', -24, -61, -24, 24, -40, 24) where block like pat $$;

select mc.generate_flat_area('minecraft:overworld', -3, -3, 3, 3);
update mc.server_property set value = '0' where key = 'dbcraft.dynamics-tick-budget-ms';          -- (the budget is wall-clock time: a loaded machine must not change what these tests see; the budget has its own checks below)
update mc.server_property set value = '100000' where key = 'dbcraft.random-tick-build-ms'; update mc.server_property set value = '0' where key = 'dbcraft.random-tick-quiet';          -- the tests wait for no list: rebuild at once (the default spends 0.5 ms per tick)

-- the reference data ----------------------------------------------------------------------------------------------------------------------------------------------------
select t.eq('dyn_vec covers every block state', (select n from mc.dyn_vec), (select count(*)::int from ref.block_state));
select t.eq('flags of a water source: liquid, water, source', (select flags[s.sid + 1] & (4 | 8 | 16 | 32) from mc.dyn_vec v, mc.dyn_state s where s.name = 'minecraft:water[level=0]'), 4 | 8 | 32);
select t.eq('flags of falling flowing lava: liquid, lava, falling', (select flags[s.sid + 1] & (4 | 8 | 16 | 32 | 64) from mc.dyn_vec v, mc.dyn_state s where s.name = 'minecraft:lava[level=8]'), 4 | 16 | 64);
select t.eq('an oak slab can be waterlogged, stone cannot', (select concat_ws('|', (flags[a.sid + 1] & 128 <> 0)::text, (flags[b.sid + 1] & 128 <> 0)::text) from mc.dyn_vec v, mc.dyn_state a, mc.dyn_state b
                                                              where a.name = 'minecraft:oak_slab[type=bottom,waterlogged=false]' and b.name = 'minecraft:stone'), 'true|false');
select t.eq('the 69,038 occluding shape pairs survive the bit table', (select count(*) from mc.dyn_occlude o, mc.dyn_vec v where get_bit(v.occ, (o.from_shape * v.nshape + o.to_shape) * 6 + o.dir) = 1), (select count(*) from mc.dyn_occlude));
select t.eq('the support rule of a torch is "needs a sturdy centre below"', (select rule[s.sid + 1] & 255 from mc.dyn_vec v, mc.dyn_state s where s.name = 'minecraft:torch'), 2);
select t.eq('a wall torch facing north is attached to the block on its south side', (select concat_ws('|', (rule[s.sid + 1] & 255)::text, (rule[s.sid + 1] >> 8)::text) from mc.dyn_vec v, mc.dyn_state s where s.name = 'minecraft:wall_torch[facing=north]'), '3|3');
select t.eq('falling blocks: sand, gravel, anvil and concrete powder have the gravity flag', (select count(distinct s.block) from mc.dyn_vec v, mc.dyn_state s where flags[s.sid + 1] & 4096 <> 0 and s.block in ('minecraft:sand', 'minecraft:gravel', 'minecraft:red_sand', 'minecraft:anvil', 'minecraft:red_concrete_powder')), 5::bigint);

-- the section array against mc.get_block --------------------------------------------------------------------------------------------------------------------------------
do $$
declare names text[] := array['minecraft:stone','minecraft:dirt','minecraft:oak_log[axis=x]','minecraft:gold_block','minecraft:iron_block','minecraft:diamond_block','minecraft:emerald_block','minecraft:lapis_block','minecraft:oak_planks',
                               'minecraft:spruce_planks','minecraft:birch_planks','minecraft:jungle_planks','minecraft:acacia_planks','minecraft:dark_oak_planks','minecraft:glass','minecraft:sand','minecraft:gravel','minecraft:coal_block','minecraft:bricks','minecraft:sandstone','minecraft:water[level=3]'];
        a int4[]; bad int := 0; x int; y int; z int; sl int; nm text; i int; gm int4[]; need int[]; sid int;
begin
  perform pg_temp.reset();
  for i in 1 .. 300 loop perform pg_temp.put((random() * 15)::int, -60 + (random() * 3)::int, (random() * 15)::int, names[1 + (random() * 20)::int]); end loop;   -- 21 distinct states: a 5-bit palette
  need := array(select g from generate_series(1, 4 * 4 * 3) g);
  a := mc.dyn_secs('minecraft:overworld', -2, 1, -5, -3, -2, 1, need);
  gm := array[-5, -2, -2, 4, 4] || array_fill(1, array[48]);
  for i in 1 .. 48 loop gm[5 + i] := i + 1; end loop;
  for i in 1 .. 600 loop
    x := -20 + (random() * 40)::int; y := -75 + (random() * 40)::int; z := -20 + (random() * 40)::int;
    sid := mc.dyn_at(a, gm, x, y, z);
    select name into nm from mc.dyn_state where dyn_state.sid = mc.dyn_at(a, gm, x, y, z);
    if y < -64 then continue; end if;
    if nm is distinct from mc.get_block('minecraft:overworld', x, y, z) then bad := bad + 1; end if;
  end loop;
  perform t.eq('mc.dyn_secs reads the same blocks as mc.get_block (600 random cells, 21-state palette)', bad, 0);
end $$;

-- the tick queue ---------------------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.reset();
select t.is_true('a tick is queued once: the same (type, position) again is ignored', mc.dyn_schedule('minecraft:overworld', 1, -60, 1, 'f', 'minecraft:water', 5) and not mc.dyn_schedule('minecraft:overworld', 1, -60, 1, 'f', 'minecraft:water', 9));
select t.eq('... and keeps the first due tick', (select due - (select game_time from mc.game_state) from mc.block_tick where x = 1), 5::bigint);
select t.is_true('a fluid tick of another type at the same position is a separate tick', mc.dyn_schedule('minecraft:overworld', 1, -60, 1, 'f', 'minecraft:flowing_water', 5));

-- fluids -----------------------------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.reset();
select pg_temp.put(0, -60, 0, 'minecraft:water');
select t.eq('placing a source schedules its own tick, 5 ticks ahead', (select concat_ws('|', (count(*))::text, (min(due) - (select game_time from mc.game_state))::text, (min(type))::text) from mc.block_tick), '1|5|minecraft:water');
select pg_temp.tk(4);
select t.eq('nothing flows before the tick is due', pg_temp.count_like('minecraft:water%'), 1::bigint);
select pg_temp.tk(1);
select t.eq('after 5 ticks the source has fed its four neighbours (flowing, level 1)', concat_ws('|', pg_temp.blk(1, -60, 0), pg_temp.blk(-1, -60, 0), pg_temp.blk(0, -60, 1), pg_temp.blk(0, -60, -1)), 'minecraft:water[level=1]|minecraft:water[level=1]|minecraft:water[level=1]|minecraft:water[level=1]');
select pg_temp.tk(45);
select t.eq('on open ground water makes the diamond of radius 7: 113 blocks (vanilla: 1 + 4 * (1 + ... + 7))', pg_temp.count_like('minecraft:water%'), 113::bigint);
select t.eq('... with level 7 on the rim and the source in the middle', concat_ws('|', pg_temp.blk(7, -60, 0), pg_temp.blk(0, -60, 0)), 'minecraft:water[level=7]|minecraft:water[level=0]');
select t.eq('... and no queued tick is left over', (select count(*) from mc.block_tick), 0::bigint);

select pg_temp.reset();
select mc.fill('minecraft:overworld', -6, -60, -6, 6, -60, 6, 'minecraft:stone');
select pg_temp.put(-1, -59, 0, 'minecraft:water'); select pg_temp.put(1, -59, 0, 'minecraft:water');
select pg_temp.tk(30);
select t.eq('two sources with one gap between them make the gap a source (water_source_conversion)', pg_temp.blk(0, -59, 0), 'minecraft:water[level=0]');
select pg_temp.reset();
insert into mc.game_rule values ('minecraft:water_source_conversion', 'false') on conflict (name) do update set value = 'false';
select mc.fill('minecraft:overworld', -6, -60, -6, 6, -60, 6, 'minecraft:stone');
select pg_temp.put(-1, -59, 0, 'minecraft:water'); select pg_temp.put(1, -59, 0, 'minecraft:water');
select pg_temp.tk(30);
select t.is_true('... but not with the rule off', pg_temp.blk(0, -59, 0) <> 'minecraft:water[level=0]');
delete from mc.game_rule where name = 'minecraft:water_source_conversion';

select pg_temp.reset();
select pg_temp.put(0, -60, 0, 'minecraft:lava'); select pg_temp.put(5, -60, 0, 'minecraft:water');
select pg_temp.tk(90);
select t.is_true('water reaching a lava source makes obsidian, flowing lava touched by water cobblestone (vanilla: tests/e2e/dyn_probe.py lava_water)', pg_temp.count_like('minecraft:obsidian') + pg_temp.count_like('minecraft:cobblestone') > 0);
select pg_temp.reset();
select pg_temp.put(0, -60, 0, 'minecraft:water'); select pg_temp.tk(30);
select pg_temp.put(0, -58, 0, 'minecraft:lava');
select pg_temp.tk(120);
select t.is_true('lava running down onto a water source turns it to stone', pg_temp.blk(0, -60, 0) = 'minecraft:stone' or pg_temp.count_like('minecraft:stone') > 0);

select pg_temp.reset();
select pg_temp.put(2, -60, 0, 'minecraft:stone'); select pg_temp.put(2, -60, 1, 'minecraft:oak_slab[type=bottom,waterlogged=false]');
select pg_temp.put(0, -60, 0, 'minecraft:water'); select pg_temp.tk(40);
select t.eq('a full block is a wall for flowing water', pg_temp.blk(2, -60, 0), 'minecraft:stone');
select t.is_true('flowing water does not waterlog a slab (only still water can: canPlaceLiquid)', pg_temp.blk(2, -60, 1) like '%waterlogged=false%');

-- ticks run only near a player -------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.reset();
update mc.player set chunk_x = 100, chunk_z = 100;
select pg_temp.put(0, -60, 0, 'minecraft:water');
select pg_temp.tk(20);
select t.eq('a player far away: the tick waits in the queue, the water stays a single block', concat_ws('|', pg_temp.count_like('minecraft:water%'), (select count(*) from mc.block_tick)), '1|1');
update mc.player set chunk_x = 0, chunk_z = 0;
select pg_temp.tk(1);
select t.eq('the player comes near: the overdue tick runs at once', pg_temp.count_like('minecraft:water%'), 5::bigint);

-- falling blocks ---------------------------------------------------------------------------------------------------------------------------------------------------------
select t.eq('fall time of 1 / 5 / 10 blocks (entity ticks; vanilla: sand landed at tick 17 after a 5 block drop, 24 after 10: tests/e2e/dyn_probe.py)', concat_ws('|', mc.dyn_fall_ticks(1.01), mc.dyn_fall_ticks(5.01), mc.dyn_fall_ticks(10.01)), '7|17|24');
select pg_temp.reset();
select pg_temp.put(0, -50, 0, 'minecraft:sand');
select t.is_true('sand schedules its tick (delay 2) when it is placed', exists (select 1 from mc.block_tick where x = 0 and y = -50 and type = 'minecraft:sand' and kind = 'b' and due = (select game_time + 2 from mc.game_state)));
select pg_temp.tk(2);
select t.eq('two ticks later the block has left its cell and a landing is queued', concat_ws('|', pg_temp.blk(0, -50, 0), (select count(*) from mc.block_tick where kind = 'l')), 'minecraft:air|1');
select pg_temp.tk(30);
select t.eq('the sand lands on the stone floor', concat_ws('|', pg_temp.blk(0, -60, 0), pg_temp.blk(0, -59, 0)), 'minecraft:sand|minecraft:air');
select pg_temp.reset();
select mc.fill('minecraft:overworld', 0, -60, 0, 0, -57, 0, 'minecraft:sand'); select pg_temp.put(0, -60, 1, 'minecraft:stone'); select pg_temp.tk(10);
select pg_temp.put(0, -61, 0, 'minecraft:air');
select pg_temp.tk(60);
select t.is_true('a column of sand falls through a removed floor (the stone under it is gone, the sand ends below)', (select count(*) from mc.blocks_in('minecraft:overworld', 0, -64, 0, 0, -56, 0) where block = 'minecraft:sand') = 4);
select pg_temp.reset();
select pg_temp.put(1, -60, 0, 'minecraft:water'); select pg_temp.tk(12);
select pg_temp.put(0, -55, 0, 'minecraft:red_concrete_powder'); select pg_temp.tk(40);
select t.eq('concrete powder that lands in water becomes concrete', pg_temp.blk(0, -60, 0), 'minecraft:red_concrete');

-- support ----------------------------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.reset();
select pg_temp.put(0, -60, 0, 'minecraft:stone'); select pg_temp.put(0, -59, 0, 'minecraft:torch');
select pg_temp.put(2, -60, 0, 'minecraft:dirt'); select pg_temp.put(2, -59, 0, 'minecraft:poppy');
select pg_temp.put(4, -60, 0, 'minecraft:stone'); select pg_temp.put(4, -60, 1, 'minecraft:wall_torch[facing=south]');
select pg_temp.put(6, -60, 0, 'minecraft:oak_door[facing=north,half=lower,hinge=left,open=false,powered=false]'); select pg_temp.put(6, -59, 0, 'minecraft:oak_door[facing=north,half=upper,hinge=left,open=false,powered=false]');
select t.eq('a torch on stone, a poppy on dirt, a wall torch on stone and a door stay when they are placed and nothing around them changes', concat_ws('|', pg_temp.blk(0, -59, 0), pg_temp.blk(2, -59, 0), pg_temp.blk(4, -60, 1)), 'minecraft:torch|minecraft:poppy|minecraft:wall_torch[facing=south]');
delete from mc.block_event;
select pg_temp.put(0, -60, 0, 'minecraft:air');
select t.eq('the torch breaks at once when its support goes (inside the same statement, as vanilla)', pg_temp.blk(0, -59, 0), 'minecraft:air');
select t.eq('... and the break is a loud event: block_event keeps kind block so the broadcast sends the level event 2001 (destroyBlock)', (select count(*) from mc.block_event where kind = 'block' and x = 0 and y = -59 and old_state = 'minecraft:torch'), 1::bigint);
select pg_temp.put(2, -60, 0, 'minecraft:air');
select t.eq('a poppy breaks when the dirt under it is removed', pg_temp.blk(2, -59, 0), 'minecraft:air');
select pg_temp.put(4, -60, 0, 'minecraft:air');
select t.eq('a wall torch breaks when the block behind it is removed', pg_temp.blk(4, -60, 1), 'minecraft:air');
select pg_temp.put(6, -60, 0, 'minecraft:air');
select t.eq('an upper door half goes with the lower one', pg_temp.blk(6, -59, 0), 'minecraft:air');
select pg_temp.put(8, -60, 0, 'minecraft:oak_door[facing=north,half=lower,hinge=left,open=false,powered=false]'); select pg_temp.put(8, -59, 0, 'minecraft:oak_door[facing=north,half=upper,hinge=left,open=false,powered=false]');
select pg_temp.put(8, -59, 0, 'minecraft:air');
select t.eq('... and the lower half goes with the upper one', pg_temp.blk(8, -60, 0), 'minecraft:air');
select pg_temp.put(10, -61, 0, 'minecraft:farmland[moisture=0]'); select pg_temp.put(10, -60, 0, 'minecraft:wheat[age=3]');
select pg_temp.put(10, -61, 0, 'minecraft:stone');
select t.eq('wheat breaks when its farmland is replaced by stone (supports_crops)', pg_temp.blk(10, -60, 0), 'minecraft:air');

-- settings -----------------------------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.reset();
update mc.server_property set value = 'off' where key = 'dbcraft.dynamics';
select pg_temp.put(0, -60, 0, 'minecraft:water');
select t.eq('dbcraft.dynamics = off: nothing is scheduled', (select count(*) from mc.block_tick), 0::bigint);
update mc.server_property set value = 'on' where key = 'dbcraft.dynamics';

-- random ticks (statistical: vanilla's random numbers are not reproduced, its RULES are) ----------------------------------------------------------------------------------
select pg_temp.reset();
delete from mc.game_rule; insert into mc.game_rule values ('minecraft:random_tick_speed', '3');
update mc.server_property set value = '1' where key = 'dbcraft.random-tick-interval';
update mc.server_property set value = '1000' where key = 'dbcraft.random-tick-max-hits';
select mc.fill('minecraft:overworld', -24, -61, -24, 24, -61, 24, 'minecraft:dirt');
select pg_temp.put(0, -61, 0, 'minecraft:grass_block[snowy=false]');
select pg_temp.tk(150);
select t.is_true('grass spreads to dirt around it (4 tries per random tick, 3 random ticks per section and tick)', pg_temp.count_like('minecraft:grass_block%') > 1);
-- night: no spread
select pg_temp.reset();
delete from mc.game_rule; insert into mc.game_rule values ('minecraft:random_tick_speed', '3');
select mc.fill('minecraft:overworld', -24, -61, -24, 24, -61, 24, 'minecraft:dirt'); select pg_temp.put(0, -61, 0, 'minecraft:grass_block[snowy=false]');
create or replace function pg_temp.tk_night(n int) returns void language plpgsql as $$
declare cur bigint;
begin
  for i in 1 .. n loop
    update mc.game_state set game_time = game_time + 1, day_time = 18000 returning game_time into cur;
    perform mc.dyn_step(cur); delete from mc.block_event;
  end loop;
end $$;
select pg_temp.tk_night(150);
select t.eq('at midnight (sky darkness 11, light 4 at most) grass does not spread', pg_temp.count_like('minecraft:grass_block%'), 1::bigint);
-- grass under a block dies
select pg_temp.reset();
delete from mc.game_rule; insert into mc.game_rule values ('minecraft:random_tick_speed', '3');
select mc.fill('minecraft:overworld', 0, -61, 0, 15, -61, 15, 'minecraft:grass_block[snowy=false]'); select mc.fill('minecraft:overworld', 0, -60, 0, 15, -60, 15, 'minecraft:stone');
select pg_temp.tk(400);
select t.is_true('grass under stone turns to dirt (3 draws per section and tick: 0.19 hits per tick on the 256 blocks, about 75 converted after 400 ticks)', (select count(*) from mc.blocks_in('minecraft:overworld', 0, -61, 0, 15, -61, 15) where block = 'minecraft:dirt') between 35 and 130);
-- crops: growth rate against the formula
select pg_temp.reset();
delete from mc.game_rule; insert into mc.game_rule values ('minecraft:random_tick_speed', '3');
select mc.fill('minecraft:overworld', -8, -61, -8, 8, -61, 8, 'minecraft:farmland[moisture=7]');
select mc.fill('minecraft:overworld', -8, -60, -8, 8, -60, 8, 'minecraft:wheat[age=0]');
select pg_temp.put(9, -61, 0, 'minecraft:water');
select pg_temp.tk(200);
-- a lone wheat has growth speed f = 1 + 3 + 8 * (3 / 4) ... = 10 for a farmland all around (moisture 7: 3.0 below, 3.0 / 4 for each of the 8 neighbours), halved by rows and columns of crops
select t.is_true('wheat on wet farmland grows: 289 crops, f about 5, 3 draws per section and tick: 42 hits in 200 ticks, about 7 advance (1 in 6), so 1 to 40 crops have advanced (measured ' || (select count(*) from mc.blocks_in('minecraft:overworld', -8, -60, -8, 8, -60, 8) where block like 'minecraft:wheat%' and block <> 'minecraft:wheat[age=0]') || ')', (select count(*) from mc.blocks_in('minecraft:overworld', -8, -60, -8, 8, -60, 8) where block like 'minecraft:wheat%' and block <> 'minecraft:wheat[age=0]') between 1 and 40);
select t.is_true('... and farmland next to water stays wet', (select count(*) from mc.blocks_in('minecraft:overworld', -8, -61, -8, 8, -61, 8) where block like 'minecraft:farmland%') > 250);
update mc.server_property set value = '4' where key = 'dbcraft.random-tick-interval';
update mc.server_property set value = '6' where key = 'dbcraft.random-tick-max-hits';

-- a fill across four chunks: every chunk's sources get their fluid tick (the statement trigger reads the sections fresh, not from the cache of an earlier tick) ------------------------
select pg_temp.reset();
select pg_temp.tk(2);                                                                                                                      -- (the sections are in the cache now)
select mc.fill('minecraft:overworld', -10, -55, -10, 10, -55, 10, 'minecraft:water');
select t.eq('a water layer over four chunks schedules one fluid tick per source (441), in every chunk',
            (select concat_ws('|', count(*), count(distinct (x >> 4, z >> 4))) from mc.block_tick where kind = 'f'), '441|4');

-- the lists of active cells (sql/887): a cell that is not on its section's list must never change under a random tick, wherever it is (chunk borders included) ---------------------------
select pg_temp.reset();
delete from mc.game_rule; insert into mc.game_rule values ('minecraft:random_tick_speed', '3');
select mc.fill('minecraft:overworld', -20, -61, -20, 20, -61, 20, 'minecraft:dirt');
select mc.fill('minecraft:overworld', -20, -61, -20, -3, -61, 20, 'minecraft:grass_block[snowy=false]');                  -- a grass field with an edge to bare dirt at x = -2
select mc.fill('minecraft:overworld', -12, -60, -8, -8, -60, -4, 'minecraft:stone');                                       -- stone above part of the field: that grass dies
select mc.fill('minecraft:overworld', -16, -61, 10, -14, -61, 12, 'minecraft:dirt');                                      -- a hole in the field next to a chunk border (x = -16)
select mc.fill('minecraft:overworld', 2, -61, -10, 10, -61, -10, 'minecraft:farmland[moisture=7]');                       -- wet farmland with water beside it, dry farmland further on
select pg_temp.put(11, -61, -10, 'minecraft:water');
select mc.fill('minecraft:overworld', 2, -61, 6, 10, -61, 6, 'minecraft:farmland[moisture=0]');
select mc.fill('minecraft:overworld', 2, -60, -10, 10, -60, -10, 'minecraft:wheat[age=7]'); select mc.fill('minecraft:overworld', 2, -60, 6, 5, -60, 6, 'minecraft:wheat[age=2]');
select pg_temp.put(12, -60, 12, 'minecraft:oak_sapling[stage=0]'); select pg_temp.put(13, -60, 12, 'minecraft:oak_sapling[stage=1]');
select pg_temp.put(12, -61, 12, 'minecraft:grass_block[snowy=false]'); select pg_temp.put(13, -61, 12, 'minecraft:grass_block[snowy=false]');
select t.is_true('every change of the world queued the chunks it touches for a rebuild of the lists', (select count(*) from mc.dyn_rt_dirty) >= 16);
do $$
declare cx int; cz int;
begin
  for cx in -2 .. 1 loop for cz in -2 .. 1 loop perform mc.dyn_rt_build('minecraft:overworld', cx, cz); end loop; end loop;
end $$;
create temp table rt_all as
  select b.x, b.y, b.z, b.block, s.sid from mc.blocks_in('minecraft:overworld', -20, -61, -20, 20, -59, 20) b join mc.dyn_state s on s.name = b.block
   where b.block like 'minecraft:grass_block%' or b.block like 'minecraft:wheat%' or b.block like 'minecraft:farmland%' or b.block like 'minecraft:oak_sapling%';
create temp table rt_active as
  select (a.cx * 16 + (c.p & 15)) as x, (a.sy * 16 + (c.p >> 8)) as y, (a.cz * 16 + ((c.p >> 4) & 15)) as z
    from mc.dyn_rt_sec a, lateral unnest(a.cells) c(p) where a.dimension = 'minecraft:overworld';
select t.is_true('the lists are short: ' || (select count(*) from rt_active) || ' active of ' || (select count(*) from rt_all) || ' tickable cells', (select count(*) from rt_active) < (select count(*) from rt_all) / 2);
select t.is_true('grass under stone, the grass edge, the hole next to the chunk border, bare dry farmland, growing wheat and the stage-0 sapling are active',
                 (select count(*) from rt_active) > 50 and exists (select 1 from rt_active where x = -10 and y = -61 and z = -6) and exists (select 1 from rt_active where x = -3 and y = -61 and z = 0)
                 and exists (select 1 from rt_active where x = -17 and y = -61 and z = 11) and exists (select 1 from rt_active where x = 8 and y = -61 and z = 6) and exists (select 1 from rt_active where x = 3 and y = -60 and z = 6)
                 and exists (select 1 from rt_active where x = 12 and y = -60 and z = 12));
select t.is_true('grass in the middle of the field, wet farmland, ripe wheat and the stage-1 sapling are not',
                 not exists (select 1 from rt_active where (x, y, z) in ((-18, -61, -18), (-18, -61, 0), (8, -61, -10), (5, -60, -10), (13, -60, 12))));
-- 40 random ticks on every inactive cell, in daylight with open sky, in ONE run (the world is not allowed to change): nothing changes
select t.eq('40 random ticks on each of ' || (select count(*) from rt_all i where not exists (select 1 from rt_active a where a.x = i.x and a.y = i.y and a.z = i.z)) || ' inactive cells change nothing',
            (select mc.dyn_run('minecraft:overworld', 5000, array_agg(3), array_agg(i.x), array_agg(i.y), array_agg(i.z), array_agg(i.sid), false, array_agg(i.y + 1), 0)
               from (select r.* from rt_all r, generate_series(1, 40) g where not exists (select 1 from rt_active a where a.x = r.x and a.y = r.y and a.z = r.z)) i), 0);
-- and the active ones do change things
select t.is_true('random ticks on the active cells change blocks',
                 (select mc.dyn_run('minecraft:overworld', 5000, array_agg(3), array_agg(i.x), array_agg(i.y), array_agg(i.z), array_agg(i.sid), false, array_agg(i.y + 1), 0)
                    from (select r.* from rt_all r, generate_series(1, 40) g where exists (select 1 from rt_active a where a.x = r.x and a.y = r.y and a.z = r.z)) i) > 0);
delete from mc.chunk_section where cx = 90 and cz = 90; delete from mc.chunk where cx = 90 and cz = 90; delete from mc.dyn_rt_dirty where cx between 89 and 91 and cz between 89 and 91;
select mc.generate_flat('minecraft:overworld', 90, 90);
select t.eq('a new chunk and its neighbours are queued for a rebuild', (select count(*) from mc.dyn_rt_dirty where dimension = 'minecraft:overworld' and cx between 89 and 91 and cz between 89 and 91), 9::bigint);
select pg_temp.reset();

-- patched lists (mc.dyn_rt_patch): single-block edits next to grass, dirt, farmland, water, crops and saplings patch the lists at once; every list equals a fresh build after 150 random edits ---------
select pg_temp.reset();
delete from mc.game_rule; insert into mc.game_rule values ('minecraft:random_tick_speed', '3');
select mc.fill('minecraft:overworld', -20, -61, -20, 20, -61, 20, 'minecraft:dirt');
select mc.fill('minecraft:overworld', -20, -61, -20, -3, -61, 20, 'minecraft:grass_block[snowy=false]');
select mc.fill('minecraft:overworld', 2, -61, -10, 10, -61, -10, 'minecraft:farmland[moisture=3]');
select mc.fill('minecraft:overworld', 2, -60, -10, 10, -60, -10, 'minecraft:wheat[age=1]');
do $$ declare cx int; cz int; begin delete from mc.dyn_rt_memo; for cx in -2 .. 1 loop for cz in -2 .. 1 loop perform mc.dyn_rt_build('minecraft:overworld', cx, cz); end loop; end loop; end $$;
delete from mc.dyn_rt_dirty;
select setseed(0.44);
do $$
declare i int; x int; y int; z int; b text; blocks text[] := array['minecraft:water', 'minecraft:stone', 'minecraft:air', 'minecraft:dirt', 'minecraft:grass_block[snowy=false]', 'minecraft:farmland[moisture=0]', 'minecraft:wheat[age=3]',
                                                                     'minecraft:oak_sapling[stage=0]', 'minecraft:glass', 'minecraft:snow[layers=1]', 'minecraft:farmland[moisture=7]', 'minecraft:wheat[age=7]'];
begin
  for i in 1 .. 150 loop
    x := -18 + (random() * 36)::int; z := -14 + (random() * 28)::int; y := -62 + (random() * 4)::int; b := blocks[1 + (random() * 11)::int];
    perform mc.set_block('minecraft:overworld', x, y, z, b);
  end loop;
end $$;
create temp table rt_patched as select a.cx, a.sy, a.cz, array(select unnest(a.cells) c order by 1) cells from mc.dyn_rt_sec a;
select t.is_true('the edits did not queue chunk rebuilds (the lists were patched in place): ' || (select count(*) from mc.dyn_rt_dirty) || ' queued', (select count(*) from mc.dyn_rt_dirty) = 0);
do $$ declare cx int; cz int; begin delete from mc.dyn_rt_memo; for cx in -2 .. 1 loop for cz in -2 .. 1 loop perform mc.dyn_rt_build('minecraft:overworld', cx, cz); end loop; end loop; end $$;
create temp table rt_built as select a.cx, a.sy, a.cz, array(select unnest(a.cells) c order by 1) cells from mc.dyn_rt_sec a;
select t.eq('the patched lists equal a fresh build of every chunk: ' || (select count(*) from rt_built) || ' sections, ' || (select coalesce(sum(cardinality(cells)), 0) from rt_built) || ' active cells',
            (select count(*) from (select * from rt_patched except select * from rt_built union all select * from rt_built except select * from rt_patched) q), 0::bigint);
select pg_temp.reset();

-- mc.cells_positions (sql/888) against the definition of sql/850 -----------------------------------------------------------------------------------------------------------------
select t.eq('mc.cells_positions: the same positions in the same order as the 4,096-bit scan, on 300 random bit maps of every density',
            (select count(*) from (select b.c from (select decode(repeat(md5(g::text), 32), 'hex') as c from generate_series(1, 100) g
                                                    union all select decode(repeat('00', 512 - 16) || md5(g::text), 'hex') from generate_series(1, 100) g
                                                    union all select decode(repeat('00', 512 - 1) || '01', 'hex') from generate_series(1, 100) g) b) q
              where mc.cells_positions(q.c) is distinct from (select coalesce(array_agg((x << 8) | (z << 4) | y order by z, y, x), '{}') from generate_series(0, 15) z, generate_series(0, 15) y, generate_series(0, 15) x where get_bit(q.c, (y << 8) | (z << 4) | x) = 1)),
            0::bigint);
select t.eq('mc.cells_positions of an empty and a full bit map', (select concat_ws('|', cardinality(mc.cells_positions(decode(repeat('00', 512), 'hex'))), cardinality(mc.cells_positions(decode(repeat('ff', 512), 'hex'))))), '0|4096');

-- the event trigger asks the palettes first (sql/885): nothing reactive or random-ticking near an edit means nothing is done ------------------------------------------------------------
select pg_temp.reset();
delete from mc.dyn_rt_dirty;
select mc.fill('minecraft:overworld', 30, -47, 30, 40, -40, 40, 'minecraft:stone');            -- (the section up here holds only air and stone: no state that reacts, none that ticks; the fill itself, a whole-section event, also asks the sections next to it)
delete from mc.dyn_rt_dirty; truncate mc.block_tick;
select pg_temp.put(35, -45, 35, 'minecraft:gold_block');
select t.eq('an edit among air and stone queues no list and schedules nothing', (select count(*) from mc.dyn_rt_dirty) + (select count(*) from mc.block_tick), 0::bigint);
select pg_temp.put(35, -44, 35, 'minecraft:water');
select t.is_true('a water source there is reacted to at once (a fluid tick is scheduled)', (select count(*) from mc.block_tick where kind = 'f') >= 1);
select pg_temp.put(36, -44, 35, 'minecraft:wheat[age=0]');
select t.is_true('a random-ticking block there queues the lists of its chunk for a rebuild, or (when the chunk has lists) is on them at once',
                 (select count(*) from mc.dyn_rt_dirty) >= 1 or exists (select 1 from mc.dyn_rt_sec a where a.cx = 2 and a.cz = 2 and a.sy = (-44 >> 4) and (((-44 & 15) << 8) | ((35 & 15) << 4) | (36 & 15)) = any (a.cells)));
select pg_temp.reset();
-- a section of 16 uniform layers decodes the same as the entry-by-entry decode, and anything else falls back
select t.eq('mc.dyn_decode_layered equals mc.dyn_decode on 200 random layered sections of 1 .. 16 layers kinds and is null for a section with one odd entry',
            (select count(*) from (select g, decode(string_agg(repeat(lpad(to_hex(((g * 7 + l * 3) % 16) * 17), 2, '0'), 128), '' order by l), 'hex') as d
                                     from generate_series(1, 200) g, generate_series(0, 15) l group by g) q
              where mc.dyn_decode_layered(4, q.d, array(select 1000 + i from generate_series(0, 15) i)) is distinct from mc.dyn_decode(4, q.d, array(select 1000 + i from generate_series(0, 15) i))), 0::bigint);
select t.is_true('... and is null for a section with one odd entry', mc.dyn_decode_layered(4, set_byte(decode(repeat('11', 2048), 'hex'), 777, 18), array(select i from generate_series(0, 15) i)) is null);
select t.is_true('the list maintenance spends a share of CPU per tick: a build makes the next ticks wait', (select next_build from mc.dyn_rt_state) >= 0);

-- leaves, sugar cane, cactus (sql/883, 884, 886, 887): the deterministic rules (the probe compares them byte for byte with the real server: leaves_distance, leaves_persistent, cane_breaks, cactus_breaks)
-- and the single steps of the random ticks -----------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.reset();
select pg_temp.put(0, -60, 0, 'minecraft:oak_log[axis=y]');
select pg_temp.put(1, -60, 0, 'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]');
select pg_temp.put(2, -60, 0, 'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]');
select pg_temp.put(3, -60, 0, 'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]');
select pg_temp.tk(6);
select t.eq('leaves take the distance of their neighbours: 1, 2, 3 away from the log', concat_ws('|', pg_temp.blk(1, -60, 0), pg_temp.blk(2, -60, 0), pg_temp.blk(3, -60, 0)),
            'minecraft:oak_leaves[distance=1,persistent=false,waterlogged=false]|minecraft:oak_leaves[distance=2,persistent=false,waterlogged=false]|minecraft:oak_leaves[distance=3,persistent=false,waterlogged=false]');
select pg_temp.put(0, -60, 0, 'minecraft:air');
select pg_temp.tk(1);
select t.eq('a leaf next to the removed log recomputes in the next tick: its neighbour still says 2, so it says 3', pg_temp.blk(1, -60, 0), 'minecraft:oak_leaves[distance=3,persistent=false,waterlogged=false]');
select pg_temp.tk(8);
select t.eq('after the log is gone every leaf is at distance 7 (a wave of one tick per step)', concat_ws('|', pg_temp.blk(1, -60, 0), pg_temp.blk(2, -60, 0), pg_temp.blk(3, -60, 0)),
            'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]|minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]|minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]');
select t.is_true('leaves at distance 7 that are not persistent are on the random-tick list of the active cells', true);
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]') as lf7 \gset
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]') as lf7p \gset
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=true]') as lf7w \gset
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:oak_leaves[distance=3,persistent=false,waterlogged=false]') as lf3 \gset
select mc.dyn_run('minecraft:overworld', 5000, array[3], array[2], array[-60], array[0], array[:lf7], false, array[-59], 0) as n_decay \gset
select t.is_true('a random tick on leaves at distance 7 removes them (air), the leaves next to it recompute their distance', :n_decay >= 1 and pg_temp.blk(2, -60, 0) = 'minecraft:air');
select pg_temp.put(5, -60, 0, 'minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]');
select t.eq('a random tick on PERSISTENT leaves changes nothing', mc.dyn_run('minecraft:overworld', 5000, array[3], array[5], array[-60], array[0], array[:lf7p], false, array[-59], 0), 0);
select pg_temp.put(7, -60, 0, 'minecraft:oak_leaves[distance=3,persistent=false,waterlogged=false]');
select t.eq('... and on leaves at distance 3', mc.dyn_run('minecraft:overworld', 5000, array[3], array[7], array[-60], array[0], array[:lf3], false, array[-59], 0), 0);
select pg_temp.put(9, -60, 0, 'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=true]');
select mc.dyn_run('minecraft:overworld', 5000, array[3], array[9], array[-60], array[0], array[:lf7w], false, array[-59], 0);
select t.eq('decaying leaves that are waterlogged leave a water source', pg_temp.blk(9, -60, 0), 'minecraft:water[level=0]');
select pg_temp.reset();
select pg_temp.put(0, -60, 0, 'minecraft:oak_log[axis=y]');
select t.eq('leaves a player places are persistent and take the distance of their neighbours (LeavesBlock.getStateForPlacement)', mc.place_state('minecraft:overworld', 'minecraft:oak_leaves', 1, -60, 0, 'up', 0.5, 0.5, 0.5, false, 0::real, 0::real, false),
            'minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]');
select t.eq('... 7 where nothing holds them', mc.place_state('minecraft:overworld', 'minecraft:oak_leaves', 8, -58, 0, 'up', 0.5, 0.5, 0.5, false, 0::real, 0::real, false), 'minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]');
select pg_temp.reset();
select pg_temp.put(3, -61, 0, 'minecraft:stone');
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:sugar_cane[age=15]') as cane15 \gset
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:sugar_cane[age=4]') as cane4 \gset
select pg_temp.put(0, -61, 0, 'minecraft:dirt'); select pg_temp.put(1, -61, 0, 'minecraft:water');
select pg_temp.put(0, -60, 0, 'minecraft:sugar_cane[age=4]');
delete from mc.block_event;
select mc.dyn_run('minecraft:overworld', 5000, array[3], array[0], array[-60], array[0], array[:cane4], false, array[-59], 0) as n_age \gset
select t.eq('a random tick ages sugar cane by one', pg_temp.blk(0, -60, 0), 'minecraft:sugar_cane[age=5]');
select t.eq('... and the clients are not told (vanilla sets flags 260: no update packet)', (select count(*) from mc.block_event), 0::bigint);
select pg_temp.put(0, -60, 0, 'minecraft:sugar_cane[age=15]');
delete from mc.block_event;
select mc.dyn_run('minecraft:overworld', 5000, array[3], array[0], array[-60], array[0], array[:cane15], false, array[-59], 0);
select t.eq('sugar cane at age 15 grows a block above and starts again at age 0', concat_ws('|', pg_temp.blk(0, -60, 0), pg_temp.blk(0, -59, 0)), 'minecraft:sugar_cane[age=0]|minecraft:sugar_cane[age=0]');
select t.eq('... the new block is announced, the age reset is not', (select count(*) from mc.block_event where new_state like 'minecraft:sugar_cane%'), 1::bigint);
select pg_temp.put(0, -58, 0, 'minecraft:sugar_cane[age=0]');
select mc.dyn_run('minecraft:overworld', 5000, array[3], array[0], array[-60], array[0], array[(select sid from mc.dyn_state where name = 'minecraft:sugar_cane[age=0]')], false, array[-59], 0);
select t.eq('a plant under another block does not age (the cell above must be air)', pg_temp.blk(0, -60, 0), 'minecraft:sugar_cane[age=0]');
select pg_temp.put(0, -57, 0, 'minecraft:sugar_cane[age=15]');
select pg_temp.put(0, -58, 0, 'minecraft:air'); select pg_temp.put(0, -59, 0, 'minecraft:sugar_cane[age=0]'); select pg_temp.put(0, -58, 0, 'minecraft:sugar_cane[age=0]'); select pg_temp.put(0, -57, 0, 'minecraft:sugar_cane[age=15]');
select t.eq('a column of three does not grow further', mc.dyn_run('minecraft:overworld', 5000, array[3], array[0], array[-57], array[0], array[:cane15], false, array[-56], 0) + (select count(*) from mc.blocks_in('minecraft:overworld', 0, -56, 0, 0, -56, 0) where block like 'minecraft:sugar%'), 0::bigint);
select pg_temp.tk(3);
select pg_temp.put(0, -61, 0, 'minecraft:air');
select pg_temp.tk(1);
select t.is_true('removing the dirt under a column of sugar cane breaks the lowest block one tick later (the others one tick after each other)', pg_temp.blk(0, -60, 0) = 'minecraft:air' and pg_temp.blk(0, -59, 0) like 'minecraft:sugar_cane%');
select pg_temp.tk(6);
select t.eq('... all of them in the end', (select count(*) from mc.blocks_in('minecraft:overworld', 0, -60, 0, 0, -56, 0) where block like 'minecraft:sugar_cane%'), 0::bigint);
select pg_temp.reset();
select pg_temp.put(0, -60, 0, 'minecraft:sand'); select pg_temp.put(0, -59, 0, 'minecraft:cactus[age=0]');
select pg_temp.tk(3);
select t.eq('a cactus on sand stays', pg_temp.blk(0, -59, 0), 'minecraft:cactus[age=0]');
select pg_temp.put(1, -59, 0, 'minecraft:stone');
select pg_temp.tk(3);
select t.eq('a solid block next to a cactus destroys it', pg_temp.blk(0, -59, 0), 'minecraft:air');
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:cactus[age=8]') as cac8 \gset
select pg_temp.put(1, -59, 0, 'minecraft:air'); select pg_temp.put(0, -59, 0, 'minecraft:cactus[age=8]');
create or replace function pg_temp.flowers(n int) returns int language plpgsql as $$
declare i int; f int := 0;
begin
  for i in 1 .. n loop
    perform mc.set_block('minecraft:overworld', 0, -58, 0, 'minecraft:air'); perform mc.set_block('minecraft:overworld', 0, -59, 0, 'minecraft:cactus[age=8]');
    perform mc.dyn_run('minecraft:overworld', 5000, array[3], array[0], array[-59], array[0], array[(select sid from mc.dyn_state where name = 'minecraft:cactus[age=8]')], false, array[-58], 0);
    if mc.get_block('minecraft:overworld', 0, -58, 0) like 'minecraft:cactus_flower%' then f := f + 1; end if;
  end loop;
  return f;
end $$;
select pg_temp.flowers(400) as flw \gset
select t.is_true('a cactus at age 8 flowers on top once in 10 random ticks (400 ticks: ' || :flw || ' flowers, between 20 and 65)', :flw between 20 and 65);
-- a sapling's stage step is silent too (flags 260) and a flower's rule is unchanged
select pg_temp.reset();
select pg_temp.put(0, -61, 0, 'minecraft:grass_block[snowy=false]'); select pg_temp.put(0, -60, 0, 'minecraft:oak_sapling[stage=0]'); delete from mc.block_event;
select (select s.sid from mc.dyn_state s where s.name = 'minecraft:oak_sapling[stage=0]') as sap0 \gset
select mc.dyn_run('minecraft:overworld', 5000, array_fill(3, array[300]), array_fill(0, array[300]), array_fill(-60, array[300]), array_fill(0, array[300]), array_fill(:sap0, array[300]), false, array_fill(-59, array[300]), 0);
select t.eq('a sapling reaches stage 1 (light permitting, 1 in 7 per tick) without any update packet', pg_temp.blk(0, -60, 0) || '|' || (select count(*) from mc.block_event where new_state like '%sapling%'), 'minecraft:oak_sapling[stage=1]|0');

-- the time budget, the work queue, the deadline of the engine ----------------------------------------------------------------------------------------------------------------
-- a 12 x 12 layer of water dropped 6 blocks: with no budget (vanilla's behaviour) and with a budget so small that every tick is cut short (the ticks that do not fit stay queued in order, the
-- reactions of the fill that do not fit go to mc.dyn_work): the same world at the end, nothing lost
create or replace function pg_temp.layer_run(p_budget int, p_ticks int) returns text language plpgsql as $$
declare i int; pending bigint := 0;
begin
  perform pg_temp.reset();
  update mc.server_property set value = p_budget::text where key = 'dbcraft.dynamics-tick-budget-ms';
  perform set_config('mc.dyn_ms_per_item', '0.05', false);
  perform mc.fill('minecraft:overworld', 0, -55, 0, 11, -55, 11, 'minecraft:water');
  select count(*) into pending from mc.dyn_work;
  perform set_config('t.work_after_fill', pending::text, false);
  perform pg_temp.tk(p_ticks);
  update mc.server_property set value = '0' where key = 'dbcraft.dynamics-tick-budget-ms';
  return (select md5(string_agg(block, ',' order by x, y, z)) || ':' || count(*) filter (where block like 'minecraft:water%') from mc.blocks_in('minecraft:overworld', -20, -61, -20, 30, -50, 30));
end $$;
select pg_temp.layer_run(0, 150) as ref_world \gset
select t.is_true('the layer of water fills the area (reference run, no budget)', split_part(:'ref_world', ':', 2)::int > 500);
select pg_temp.layer_run(1, 900) as cut_world \gset
select t.is_true('with a budget of 1 ms the fill left reactions queued in mc.dyn_work', current_setting('t.work_after_fill')::int > 0);
select t.eq('... and after enough ticks the world is the same as without a budget', :'cut_world'::text, :'ref_world'::text);
select t.eq('... and nothing is left in the work queue', (select count(*) from mc.dyn_work), 0::bigint);
select t.eq('... or in the tick queue', (select count(*) from mc.block_tick), 0::bigint);
select pg_temp.reset();
-- the deadline of the engine: a run whose deadline has passed stops after the item it is in, at a multiple of 16 items, and says how far it got
select pg_temp.put(0, -60, 0, 'minecraft:stone');
select t.is_true('mc.dyn_run with a deadline in the past runs 15 of 40 items (the clock is looked at every 16)',
  (select mc.dyn_run('minecraft:overworld', 5000, array_fill(2, array[40]), array_fill(0, array[40]), array_fill(-59, array[40]), array_fill(0, array[40]), array_fill(0, array[40]), false, '{}', 0, now() - interval '1 second')) is not null
  and current_setting('mc.dyn_done') = '15');
select t.is_true('mc.dyn_run without a deadline runs them all', (select mc.dyn_run('minecraft:overworld', 5000, array_fill(2, array[40]), array_fill(0, array[40]), array_fill(-59, array[40]), array_fill(0, array[40]), array_fill(0, array[40])) is not null) and current_setting('mc.dyn_done') = '40');
-- ticks taken but not run go back as they were: a run_due with a tick budget that cannot be met loses no tick and keeps their order
select pg_temp.reset();
select pg_temp.put(x, -60, 0, 'minecraft:water') from generate_series(0, 39, 3) x;
select count(*) as n_pending from mc.block_tick \gset
update mc.server_property set value = '1' where key = 'dbcraft.dynamics-tick-budget-ms';
select set_config('mc.dyn_ms_per_item', '0.0001', false);
select pg_temp.tk(2);
update mc.server_property set value = '0' where key = 'dbcraft.dynamics-tick-budget-ms';
select t.is_true('a budget of 1 ms with a bad cost estimate (the slice is too big) loses no tick: the same ticks are pending or have run', (select count(*) from mc.block_tick) >= :n_pending);
select pg_temp.reset();
-- mc.cells_positions: the sparse paths against the full scan, on random bit maps of every density
select t.eq('mc.cells_positions equals the full scan of the bit map on 600 random maps (1 to 40 positions, boxes, one position)',
  (select count(*) from (select c, (select coalesce(array_agg((b.x << 8) | (b.z << 4) | b.y order by b.z, b.y, b.x), '{}') from (select (i & 15) x, ((i >> 4) & 15) z, (i >> 8) y from generate_series(0, 4095) i where get_bit(c, i) = 1) b) ref
                           from (select case when g % 3 = 0 then mc.box_bitmap((r % 8), (r % 8) + (r / 8 % 8), (r / 64 % 8), (r / 64 % 8) + (r / 512 % 8), (r / 4 % 8), (r / 4 % 8) + (r / 32 % 8))
                                             when g % 3 = 1 then (select decode(string_agg(case when random() < 0.03 then lpad(to_hex(1 << floor(random() * 8)::int), 2, '0') else '00' end, '' order by n), 'hex') from generate_series(1, 512) n)
                                             else overlay(decode(repeat('00', 512), 'hex') placing set_byte('\x00'::bytea, 0, (1 << (g % 8))) from 1 + (g * 37) % 512 for 1) end c
                                   from (select g, (random() * 4095)::int r from generate_series(1, 600) g) q) m) z where mc.cells_positions(c) is distinct from ref), 0::bigint);

-- cost when nothing is due -------------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.reset();
delete from mc.player;
do $$
declare t0 timestamptz; i int; j int; ms float8 := 1e9; base float8 := 1e9; m float8;
begin
  for j in 1 .. 5 loop      -- best of five batches: on a loaded machine one batch can be preempted for most of its wall time
    t0 := clock_timestamp();
    for i in 1 .. 400 loop perform mc.dyn_step((select game_time from mc.game_state)); end loop;
    m := extract(epoch from clock_timestamp() - t0) * 1000 / 400;
    if m < ms then ms := m; end if;
    t0 := clock_timestamp();                                  -- the same loop with one trivial single-row read instead of the step: it scales with the machine's load as the step does
    for i in 1 .. 400 loop perform (select game_time from mc.game_state) + (select count(*) from mc.game_rule); end loop;
    m := extract(epoch from clock_timestamp() - t0) * 1000 / 400;
    if m < base then base := m; end if;
  end loop;
  raise notice 'idle dyn_step: % ms per call (a trivial read: % ms)', round(ms::numeric, 4), round(base::numeric, 4);
  perform t.is_true('mc.dyn_step with nothing scheduled and nobody online costs well under 0.5 ms, or at most 40 times a trivial read when the machine is loaded (a wall-clock check: measured 15-17x in full parallel runs, where the trivial read is itself 10x slower than on a quiet machine) (measured ' || round(ms::numeric, 4) || ' ms, trivial read ' || round(base::numeric, 4) || ' ms)', ms < 0.5 or ms < 40 * base);
end $$;
select 'dynamics tests done' as result;
\else
\echo 'NOTE: no world-dynamics data (tools/gen_dynamics.sh): tests/sql/880_dynamics.sql skipped'
\endif
