-- The rewritten mc.blocks (sql/290): same rows as before, coordinate filters applied before unpacking, section coordinates exposed, triggers intact.
\! python3 tools/load_world_ref.py
insert into mc.dimension (name) values ('dbcraft:v290') on conflict do nothing;
delete from mc.flat_layer where dimension = 'dbcraft:v290';
insert into mc.flat_layer (dimension, y, block)
select 'dbcraft:v290', y, b from (values (-64, 'minecraft:bedrock'), (-63, 'minecraft:dirt'), (-62, 'minecraft:dirt'), (-61, 'minecraft:grass_block'),
                                        (-50, 'minecraft:stone'), (-20, 'minecraft:water'), (40, 'minecraft:glass')) l(y, b);
delete from mc.chunk where dimension = 'dbcraft:v290';
select mc.generate_flat('dbcraft:v290', cx, cz) from generate_series(0, 1) cx, generate_series(-1, 0) cz;
-- some edits so the palettes grow and a section has several block types (including air holes)
select mc.set_block('dbcraft:v290', 3, -61, 3, 'minecraft:gold_block');
select mc.set_block('dbcraft:v290', 20, -62, -5, 'minecraft:oak_log[axis=y]');
select mc.set_block('dbcraft:v290', 5, -63, 5, 'minecraft:air');
select mc.set_block('dbcraft:v290', 7, 100, 7, 'minecraft:diamond_block');       -- a section above the generated ones

-- 1. the same rows as mc.blocks_in over the whole generated area
select t.eq('same number of rows as blocks_in',
            (select count(*) from mc.blocks where dimension = 'dbcraft:v290'),
            (select count(*) from mc.blocks_in('dbcraft:v290', 0, -64, -16, 31, 319, 15)));
select t.is_true('...and byte-identical rows',
  (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks where dimension = 'dbcraft:v290')
= (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks_in('dbcraft:v290', 0, -64, -16, 31, 319, 15)));
select t.is_true('air is not listed', not exists (select 1 from mc.blocks where dimension = 'dbcraft:v290' and block like 'minecraft:air%'));
select t.eq('the removed block is gone', (select count(*) from mc.blocks where dimension = 'dbcraft:v290' and x = 5 and y = -63 and z = 5)::int, 0);

-- 2. point queries
select t.eq('point query finds the block', (select block from mc.blocks where dimension = 'dbcraft:v290' and x = 3 and y = -61 and z = 3), 'minecraft:gold_block');
select t.eq('...the same as get_block', (select block from mc.blocks where dimension = 'dbcraft:v290' and x = 20 and y = -62 and z = -5), mc.get_block('dbcraft:v290', 20, -62, -5));
select t.eq('a block in a negative chunk, in the high section', (select block from mc.blocks where dimension = 'dbcraft:v290' and x = 7 and y = 100 and z = 7), 'minecraft:diamond_block');
select t.eq('an air position returns no row', (select count(*) from mc.blocks where dimension = 'dbcraft:v290' and x = 3 and y = 200 and z = 3)::int, 0);
select t.eq('a range filter works too (one layer of the first chunk)', (select count(*) from mc.blocks where dimension = 'dbcraft:v290' and y = -64 and x between 0 and 15 and z between 0 and 15)::int, 256);

-- 3. the section coordinates
select t.eq('cx, cz, sy are the section of x, z, y', (select count(*) from mc.blocks where dimension = 'dbcraft:v290' and (cx <> x >> 4 or cz <> z >> 4 or sy <> y >> 4))::int, 0);
select t.eq('filtering on them gives the same block', (select block from mc.blocks where dimension = 'dbcraft:v290' and cx = 0 and cz = 0 and sy = -4 and x = 3 and y = -61 and z = 3), 'minecraft:gold_block');

-- 4. with the section coordinates the plan uses the section index, not a scan of the table
create function pg_temp.plan(q text) returns text language plpgsql as $$
declare r text; t text := '';
begin for r in execute 'explain ' || q loop t := t || r || E'\n'; end loop; return t; end $$;
select t.is_true('with section coordinates: an index scan, no sequential scan on chunk_section',
  pg_temp.plan($q$select * from mc.blocks where dimension = 'dbcraft:v290' and cx = 0 and cz = 0 and sy = -4 and x = 3 and y = -61 and z = 3$q$) like '%Index%chunk_section_pkey%'
  and pg_temp.plan($q$select * from mc.blocks where dimension = 'dbcraft:v290' and cx = 0 and cz = 0 and sy = -4 and x = 3 and y = -61 and z = 3$q$) not like '%Seq Scan on chunk_section%');
select t.is_true('without them the coordinates are filtered before the block is looked up (the block lookup is the last node)',
  pg_temp.plan($q$select * from mc.blocks where dimension = 'dbcraft:v290' and x = 3 and y = -61 and z = 3$q$) like '%Join Filter: %lx%' or
  pg_temp.plan($q$select * from mc.blocks where dimension = 'dbcraft:v290' and x = 3 and y = -61 and z = 3$q$) like '%* 16%');

-- 5. the INSTEAD OF triggers still work through the new definition
update mc.blocks set block = 'minecraft:emerald_block' where dimension = 'dbcraft:v290' and x = 3 and y = -61 and z = 3;
select t.eq('UPDATE through the view sets the block', mc.get_block('dbcraft:v290', 3, -61, 3), 'minecraft:emerald_block');
delete from mc.blocks where dimension = 'dbcraft:v290' and x = 3 and y = -61 and z = 3;
select t.eq('DELETE through the view makes it air', mc.get_block('dbcraft:v290', 3, -61, 3), 'minecraft:air');
insert into mc.blocks (dimension, x, y, z, block) values ('dbcraft:v290', 3, -61, 3, 'minecraft:lapis_block');
select t.eq('INSERT through the view places it', mc.get_block('dbcraft:v290', 3, -61, 3), 'minecraft:lapis_block');
update mc.blocks set block = 'minecraft:stone' where dimension = 'dbcraft:v290' and cx = 1 and cz = -1 and sy = -4 and x = 17 and y = -64 and z = -3;
select t.eq('UPDATE with section coordinates', mc.get_block('dbcraft:v290', 17, -64, -3), 'minecraft:stone');

-- clean up (other tests expect no leftovers in the dimension list they use)
delete from mc.chunk where dimension = 'dbcraft:v290';
delete from mc.flat_layer where dimension = 'dbcraft:v290';
delete from mc.dimension where name = 'dbcraft:v290';
