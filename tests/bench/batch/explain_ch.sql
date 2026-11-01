-- EXPLAIN ANALYZE of the batched chunk-streaming statements on a state where 25 of 500 players crossed a chunk border.  Everything is rolled back.
begin;
select ibench.setup(500, 100);
update mc.player set chunk_x = chunk_x + 1 where conn_id % 20 = 0;
\echo ---- generation check
explain (analyze, buffers, costs off, timing off)
select mc.generate_flat('minecraft:overworld', t.x, t.z)
   from (select distinct p.chunk_x + dx as x, p.chunk_z + dz as z
           from net.conn c join mc.player p on p.conn_id = c.conn_id, generate_series(-11, 11) dx, generate_series(-11, 11) dz
          where c.state = 'play' and not c.closing and c.view_cx is not null and (p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz)
            and (abs(p.chunk_x + dx - c.view_cx) > 11 or abs(p.chunk_z + dz - c.view_cz) > 11)) t
  where (select true from mc.chunk k where k.dimension = 'minecraft:overworld' and k.cx = t.x and k.cz = t.z) is null;
rollback;
