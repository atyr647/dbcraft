-- Solidity masks and floor summaries of the 100 x 100 chunk benchmark world, built up front (a first-touch build costs about 1.7 ms per chunk and a missing mask 20 ms: they would land in measured ticks).
select count(*) as masks_built from (select mc.entity_build_mask('minecraft:overworld', a.x, b.z, c.sy)
  from generate_series(-50, 49) a(x), generate_series(-50, 49) b(z), generate_series(-4, -3) c(sy)
 where not exists (select 1 from mc.solid_mask m2 where m2.dimension = 'minecraft:overworld' and m2.cx = a.x and m2.cz = b.z and m2.sy = c.sy)) w;
select count(*) as floors_built from (select mc.entity_floor_build('minecraft:overworld', a.x, b.z)
  from generate_series(-50, 49) a(x), generate_series(-50, 49) b(z)
 where not exists (select 1 from mc.entity_floor f where f.dimension = 'minecraft:overworld' and f.cx = a.x and f.cz = b.z and f.tops is not null)) w;
