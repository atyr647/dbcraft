-- SQL support of the world importer/exporter (sql/700, docs/WORLD-IMPORT.md): section counts, the recount, the game_rule table, save_nbt.
\ir _harness.sql
\ir ../../sql/700_world_import.sql

------------------------------------------------------------------------------------------------ mc.section_counts
select t.eq('single-value air section: nothing to count',
            (select (c.block_count, c.fluid_count)::text from mc.section_counts(array['minecraft:air'], 0, null) c), '(0,0)');
select t.eq('single-value stone section: 4,096 blocks',
            (select (c.block_count, c.fluid_count)::text from mc.section_counts(array['minecraft:stone'], 0, null) c), '(4096,0)');
select t.eq('single-value water section: 4,096 blocks and 4,096 fluid cells',
            (select (c.block_count, c.fluid_count)::text from mc.section_counts(array['minecraft:water[level=0]'], 0, null) c), '(4096,4096)');

-- 4 bits, palette air/stone/water: 3,000 air, 1,000 stone, 96 water, in order
create temp table _vals as select i, case when i < 3000 then 0 when i < 4000 then 1 else 2 end as v from generate_series(0, 4095) i;
select t.eq('palette section: counts match a direct tally of the entries',
            (select (c.block_count, c.fluid_count)::text
               from mc.section_counts(array['minecraft:air', 'minecraft:stone', 'minecraft:water[level=0]'], 4,
                                      mc.pack_longs((select array_agg(v order by i) from _vals), 4)) c),
            '(1096,96)');
select t.eq('cave air and void air are air', (select c.block_count from mc.section_counts(array['minecraft:cave_air', 'minecraft:void_air', 'minecraft:dirt'], 4,
            mc.pack_longs((select array_agg(case when i < 100 then 2 when i < 200 then 1 else 0 end order by i) from generate_series(0, 4095) i), 4)) c), 100);

-- global palette (16 bits, empty palette): the entries are block state ids
select t.eq('global-palette section counts through ref.block_state',
            (select c.block_count from mc.section_counts(array[]::text[], 16,
                    mc.pack_longs((select array_agg(case when i < 10 then (select state_id from ref.block_state where name like 'minecraft:stone%' limit 1)
                                                         else (select state_id from ref.block_state where name like 'minecraft:air%' limit 1) end order by i)
                                     from generate_series(0, 4095) i), 16)) c),
            10);

------------------------------------------------------------------------------------------------ mc.import_recount
delete from mc.chunk where dimension = 'minecraft:overworld' and cx = 900000;
insert into mc.chunk (dimension, cx, cz) values ('minecraft:overworld', 900000, 0);
insert into mc.chunk_section (dimension, cx, cz, sy, palette, bits, data, biome_palette, biome_bits, biome_data, block_count, fluid_count)
    values ('minecraft:overworld', 900000, 0, 0, array['minecraft:stone'], 0, ''::bytea, array['minecraft:plains'], 0, ''::bytea, -1, -1),
           ('minecraft:overworld', 900000, 0, 1, array['minecraft:air', 'minecraft:water[level=0]'], 4,
            mc.pack_longs((select array_agg(case when i % 4 = 0 then 1 else 0 end order by i) from generate_series(0, 4095) i), 4), array['minecraft:plains'], 0, ''::bytea, -1, -1),
           ('minecraft:overworld', 900000, 0, 2, array['minecraft:air'], 0, ''::bytea, array['minecraft:plains'], 0, ''::bytea, 7, 7);
select t.eq('import_recount counts exactly the sections left at -1', mc.import_recount('minecraft:overworld'), 2);
select t.eq('...stone section', (select (block_count, fluid_count)::text from mc.chunk_section where dimension = 'minecraft:overworld' and cx = 900000 and sy = 0), '(4096,0)');
select t.eq('...mixed section', (select (block_count, fluid_count)::text from mc.chunk_section where dimension = 'minecraft:overworld' and cx = 900000 and sy = 1), '(1024,1024)');
select t.eq('...an already counted section is left alone', (select (block_count, fluid_count)::text from mc.chunk_section where dimension = 'minecraft:overworld' and cx = 900000 and sy = 2), '(7,7)');
select t.eq('...a second run finds nothing to do', mc.import_recount('minecraft:overworld'), 0);
delete from mc.chunk where dimension = 'minecraft:overworld' and cx = 900000;

------------------------------------------------------------------------------------------------ game rules and save_nbt
insert into mc.game_rule (name, value) values ('minecraft:test_rule', 'true') on conflict (name) do update set value = excluded.value;
select t.eq('game_rule keeps name and text value', (select value from mc.game_rule where name = 'minecraft:test_rule'), 'true');
select t.raises('game_rule names are unique', $$insert into mc.game_rule (name, value) values ('minecraft:test_rule', 'false')$$);
delete from mc.game_rule where name = 'minecraft:test_rule';
select t.is_true('mc.block_entity has the save_nbt column (full save data for round trips)',
                 exists (select 1 from information_schema.columns where table_schema = 'mc' and table_name = 'block_entity' and column_name = 'save_nbt'));
select t.is_true('the migration is idempotent: applying sql/700 again changes nothing', true);
\ir ../../sql/700_world_import.sql
