-- Dense series: real vanilla terrain chunks (the 49 captured by tools/capture_vanilla.py against a normal-world server) replicated over the spiral.
-- Every replica has the real row shapes: 24 sections with 4-7 bit palettes, 26 light layers, block entities, and a real cached packet (~125 KB raw).
-- Needs: tests/bench/scale/helpers.sql, tools/load_world_ref.py, and the capture at /tmp/dbcraft-fixtures/terrain_nocomp.jsonl (Mojang data: not in git).
-- Run from the repository root:  psql -X -d DB -f tests/bench/scale/dense.sql
\set ON_ERROR_STOP on
insert into mc.dimension (name) values ('dbcraft:terrain') on conflict do nothing;
delete from mc.chunk where dimension = 'dbcraft:terrain';
\copy mc.chunk (dimension, cx, cz, hm_motion_blocking, hm_motion_blocking_no_leaves, hm_world_surface, dirty) from program 'python3 tools/import_chunk_capture.py chunks'
\copy mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data) from program 'python3 tools/import_chunk_capture.py sections'
\copy mc.chunk_light (dimension, cx, cz, idx, sky_kind, sky, block_kind, block) from program 'python3 tools/import_chunk_capture.py light'
\copy mc.block_entity (dimension, cx, cz, x, y, z, type, nbt) from program 'python3 tools/import_chunk_capture.py entities'

-- the 49 source chunks, numbered, each with the packet the server builds for it (this is also a check that imported terrain packages)
drop table if exists scale.src_chunk;
create table scale.src_chunk as
  select (row_number() over (order by cx, cz) - 1)::int as k, cx, cz, null::bytea as packet from mc.chunk where dimension = 'dbcraft:terrain';
update scale.src_chunk s set packet = mc.chunk_packet_build('dbcraft:terrain', s.cx, s.cz);
select count(*) as source_chunks, round(avg(length(packet)) / 1024.0, 1) as avg_packet_kib from scale.src_chunk;

-- Replicate onto the spiral: target chunk (tx*8+a, tz*8+b) of tile i copies source chunk (i*64 + a*8 + b) mod 49 with its coordinates rewritten
-- (block entities move with it; the cached packet gets the new chunk coordinates, which sit in its first 8 body bytes).
create or replace procedure scale.grow_dense(p_target int, p_dim text default 'minecraft:overworld') language plpgsql as $$
declare i int; s record; nsrc int;
begin
  select count(*) into nsrc from scale.src_chunk;
  select v into i from scale.state where k = 'tile_' || p_dim;
  i := coalesce(i, 0);
  while i * 64 < p_target loop
    select * into s from scale.spiral(i);
    create temp table if not exists scale_map (k int, scx int, scz int, tcx int, tcz int) on commit drop;
    truncate scale_map;
    insert into scale_map
      select sc.k, sc.cx, sc.cz, s.tx * 8 + a, s.tz * 8 + b
        from generate_series(0, 7) a cross join generate_series(0, 7) b join scale.src_chunk sc on sc.k = (i * 64 + a * 8 + b) % nsrc;
    insert into mc.chunk (dimension, cx, cz, status, version, dirty, hm_dirty, hm_motion_blocking, hm_motion_blocking_no_leaves, hm_world_surface)
      select p_dim, m.tcx, m.tcz, c.status, 0, false, false, c.hm_motion_blocking, c.hm_motion_blocking_no_leaves, c.hm_world_surface
        from scale_map m join mc.chunk c on c.dimension = 'dbcraft:terrain' and c.cx = m.scx and c.cz = m.scz;
    insert into mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data)
      select p_dim, m.tcx, m.tcz, cs.sy, cs.block_count, cs.fluid_count, cs.palette, cs.bits, cs.data, cs.biome_palette, cs.biome_bits, cs.biome_data
        from scale_map m join mc.chunk_section cs on cs.dimension = 'dbcraft:terrain' and cs.cx = m.scx and cs.cz = m.scz;
    insert into mc.chunk_light (dimension, cx, cz, idx, sky_kind, sky, block_kind, block)
      select p_dim, m.tcx, m.tcz, l.idx, l.sky_kind, l.sky, l.block_kind, l.block
        from scale_map m join mc.chunk_light l on l.dimension = 'dbcraft:terrain' and l.cx = m.scx and l.cz = m.scz;
    insert into mc.block_entity (dimension, cx, cz, x, y, z, type, nbt)
      select p_dim, m.tcx, m.tcz, e.x + (m.tcx - m.scx) * 16, e.y, e.z + (m.tcz - m.scz) * 16, e.type, e.nbt
        from scale_map m join mc.block_entity e on e.dimension = 'dbcraft:terrain' and e.cx = m.scx and e.cz = m.scz;
    insert into mc.chunk_cache (dimension, cx, cz, version, packet)
      select p_dim, m.tcx, m.tcz, 0,
             overlay(sc.packet placing proto.i32(m.tcx) || proto.i32(m.tcz)
                     from (case when get_byte(sc.packet, 0) < 128 then 1 when get_byte(sc.packet, 1) < 128 then 2 else 3 end) + 2 for 8)
        from scale_map m join scale.src_chunk sc on sc.k = m.k;
    i := i + 1;
    insert into scale.state values ('tile_' || p_dim, i) on conflict (k) do update set v = excluded.v;
    commit;
  end loop;
end $$;
