-- mc.blocks WHERE x, y, z: how does it scale with the number of sections?  psql -X -d DB -f tests/bench/scale/blocks_view_hazard.sql
set jit = off;
\echo == plan of the headline query (the view exposes no section coordinates, so nothing can use the section index)
explain (costs off) select * from mc.blocks where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;

\echo == the same query with a 15 s limit (cancelled = longer than 15 s at this world size)
set statement_timeout = '15s';
\timing on
select * from mc.blocks where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;
\timing off
reset statement_timeout;

\echo == per-section cost: the same filter over the first 1,000 sections only (unpack 4,096 entries each)
\timing on
select count(*) from (select * from mc.chunk_section where dimension = 'minecraft:overworld' order by cx, cz, sy limit 1000) s
  cross join lateral mc.section_blocks(s) b where s.block_count > 0 and b.x = 1 and b.y = -61 and b.z = 2;
\timing off

\echo == with the section coordinates in the query (what a user has to write today): one section, then via block_at
\timing on
select count(*) from mc.chunk_section s cross join lateral mc.section_blocks(s) b
 where s.dimension = 'minecraft:overworld' and s.cx = 0 and s.cz = 0 and s.sy = -4 and s.block_count > 0 and b.x = 1 and b.y = -61 and b.z = 2;
select * from mc.block_at('minecraft:overworld', 1, -61, 2);
\timing off
select count(*) as sections from mc.chunk_section;
