-- One digest line per component of the imported world, independent of how a section's palette happens to be ordered (so it survives an export and a re-import).
-- usage: psql -At -f tests/world_import/digest.sql        (libpq environment)
\pset tuples_only on
\pset format unaligned
select 'chunks      ' || count(*) from mc.chunk where dimension = 'minecraft:overworld';
select 'heightmaps  ' || md5(string_agg(cx || ',' || cz || ':' || hm_motion_blocking::text || hm_motion_blocking_no_leaves::text || hm_world_surface::text, ';' order by cx, cz))
  from mc.chunk where dimension = 'minecraft:overworld';
-- the block name of every cell of every section
select 'blocks      ' || md5(string_agg(h, ';' order by cx, cz, sy)) || ' (' || count(*) || ' sections)'
  from (select s.cx, s.cz, s.sy,
               case when s.bits = 0 then s.palette[1]
                    when coalesce(cardinality(s.palette), 0) = 0 then (select string_agg(b.name, ',' order by u.o) from unnest(mc.unpack_longs(s.data, s.bits, 4096)) with ordinality u(i, o) join ref.block_state b on b.state_id = u.i)
                    else (select string_agg(s.palette[u.i + 1], ',' order by u.o) from unnest(mc.unpack_longs(s.data, s.bits, 4096)) with ordinality u(i, o)) end as h
          from mc.chunk_section s where s.dimension = 'minecraft:overworld') x
  ;
select 'block counts ' || md5(string_agg(cx || ',' || cz || ',' || sy || ':' || block_count || '/' || fluid_count, ';' order by cx, cz, sy))
  from mc.chunk_section where dimension = 'minecraft:overworld';
select 'block entities ' || count(*) || ' ' || md5(coalesce(string_agg(x || ',' || y || ',' || z || ',' || type || ',' || encode(nbt, 'hex') || ',' || coalesce(encode(save_nbt, 'hex'), ''), ';' order by x, y, z), ''))
  from mc.block_entity where dimension = 'minecraft:overworld';
select 'players     ' || count(*) from mc.player;
