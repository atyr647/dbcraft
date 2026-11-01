-- Compare the rewritten mc.blocks (sql/290) with the original definition and with mc.blocks_in.  psql -X -d DB -f tests/bench/scale/blocks_view_new.sql
set jit = off;
\echo == equal on a region? new view vs mc.blocks_in over chunks (0..2, 0..2), all heights (non-air blocks)
select (select count(*) from mc.blocks where dimension = 'minecraft:overworld' and cx between 0 and 2 and cz between 0 and 2) as view_rows,
       (select count(*) from mc.blocks_in('minecraft:overworld', 0, -64, 0, 47, 319, 47)) as blocks_in_rows,
       (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks where dimension = 'minecraft:overworld' and cx between 0 and 2 and cz between 0 and 2)
     = (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks_in('minecraft:overworld', 0, -64, 0, 47, 319, 47)) as identical;

\echo == the headline query, no section coordinates (a scan of the section table, but no unpacking)
explain (costs off) select * from mc.blocks where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;
\timing on
select * from mc.blocks where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;
select * from mc.blocks where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;
\echo == with the section coordinates: one index lookup
select * from mc.blocks where dimension = 'minecraft:overworld' and cx = 0 and cz = 0 and sy = -4 and x = 1 and y = -61 and z = 2;
select * from mc.blocks where dimension = 'minecraft:overworld' and cx = 0 and cz = 0 and sy = -4 and x = 1 and y = -61 and z = 2;
\echo == an UPDATE through the view (INSTEAD OF trigger), no section coordinates, and then the block it set
update mc.blocks set block = 'minecraft:gold_block' where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;
select mc.get_block('minecraft:overworld', 1, -61, 2);
update mc.blocks set block = 'minecraft:grass_block' where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;
\timing off
select count(*) as sections from mc.chunk_section;
