-- Region queries on the section table: a box of chunks (16 x 16) inside a world that is W chunks wide.
-- With the primary key (dimension, cx, cz, sy) a range on cx and a range on cz uses cx for the index range and tests cz as a filter,
-- so the rows examined grow with the world's extent in z.  psql -X -d DB -f tests/bench/scale/region_scan.sql
set jit = off;
\echo == 16 x 16 chunk box at the centre: rows the index scan examines vs rows it returns
explain (analyze, buffers, costs off, timing off, summary on)
select count(*) from mc.chunk_section where dimension = 'minecraft:overworld' and cx between 0 and 15 and cz between 0 and 15;
\echo == the same, and a 4 x 4 box
explain (analyze, buffers, costs off, timing off, summary on)
select count(*) from mc.chunk_section where dimension = 'minecraft:overworld' and cx between 0 and 3 and cz between 0 and 3;
\echo == chunk table: 16 x 16 box (the chunk table has one row per chunk, so a third of the work)
explain (analyze, buffers, costs off, timing off, summary on)
select count(*) from mc.chunk where dimension = 'minecraft:overworld' and cx between 0 and 15 and cz between 0 and 15;
\echo == world extent
select min(cx), max(cx), min(cz), max(cz), count(*) as chunks from mc.chunk where dimension = 'minecraft:overworld';
