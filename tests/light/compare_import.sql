-- The light engine against the light vanilla saved: the chunks of an imported vanilla world (tools/world_import.py, light rows straight from the region files) are lit again from their
-- blocks by mc.light_region and compared layer by layer, sky and block, with what the files hold.
--   psql -X -f tests/light/compare_import.sql        (a scratch database with the imported world; run it right after the import: the first run keeps the files' light in lt_base)
-- Only chunks that vanilla lit with all their neighbours are comparable: the report is for the chunks with every chunk within 1, 2 and 3 chunks of them present (vanilla lit the
-- chunks at the edge of what it generated before their neighbours had their final blocks).
\set ON_ERROR_STOP on
create table if not exists lt_base as select * from mc.chunk_light;
drop table if exists lt_int1, lt_int2, lt_int3;
create table lt_int1 as select c.cx, c.cz from mc.chunk c where c.dimension = 'minecraft:overworld' and (select count(*) from mc.chunk n where n.dimension = c.dimension and abs(n.cx - c.cx) <= 1 and abs(n.cz - c.cz) <= 1) = 9;
create table lt_int2 as select c.cx, c.cz from lt_int1 c where (select count(*) from mc.chunk n where n.dimension = 'minecraft:overworld' and abs(n.cx - c.cx) <= 2 and abs(n.cz - c.cz) <= 2) = 25;
create table lt_int3 as select c.cx, c.cz from lt_int2 c where (select count(*) from mc.chunk n where n.dimension = 'minecraft:overworld' and abs(n.cx - c.cx) <= 3 and abs(n.cz - c.cz) <= 3) = 49;
\timing on
select mc.light_region('minecraft:overworld', array_agg(cx), array_agg(cz)) as rows_changed from lt_int1;
\timing off
with sets as (select 1 as d, cx, cz from lt_int1 union all select 2, cx, cz from lt_int2 union all select 3, cx, cz from lt_int3)
select s.d as chunks_within, count(distinct (s.cx, s.cz)) as chunks, count(*) as layers,
       count(*) filter (where a.sky is distinct from b.sky) as sky_arrays_differ,
       count(*) filter (where a.block is distinct from b.block) as block_arrays_differ,
       count(*) filter (where a.sky_kind is distinct from b.sky_kind or a.block_kind is distinct from b.block_kind) as kind_differs
  from sets s join mc.chunk_light a on a.dimension = 'minecraft:overworld' and a.cx = s.cx and a.cz = s.cz
  join lt_base b on (b.dimension, b.cx, b.cz, b.idx) = (a.dimension, a.cx, a.cz, a.idx)
 group by s.d order by s.d;
select 'layers in the files and not computed: ' || (select count(*) from lt_base x join lt_int3 t on t.cx = x.cx and t.cz = x.cz where not exists (select 1 from mc.chunk_light l where (l.dimension, l.cx, l.cz, l.idx) = (x.dimension, x.cx, x.cz, x.idx)))
    || ', computed and not in the files: ' || (select count(*) from mc.chunk_light l join lt_int3 t on t.cx = l.cx and t.cz = l.cz where not exists (select 1 from lt_base x where (l.dimension, l.cx, l.cz, l.idx) = (x.dimension, x.cx, x.cz, x.idx))) as layer_sets;
