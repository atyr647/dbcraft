-- ORACLE TEST on real terrain: load captured vanilla chunks as rows, re-encode them and compare the bytes; then check the derived data we compute
-- (block/fluid counts, heightmaps, light) against what vanilla computed.  Needs /tmp/dbcraft-fixtures/terrain_nocomp.jsonl (tools/capture_vanilla.py against a
-- normal-world server) and the biome list (tools/load_world_ref.py).  Skips, loudly, when either is missing.
\! python3 tools/load_world_ref.py
select count(*) > 0 as have_biomes from mc.biome \gset
create temp table expected (cx int, cz int, framed text);
\copy expected from program 'python3 tools/import_chunk_capture.py expected'
select (select count(*) from expected) > 0 and :'have_biomes'::boolean as have_capture \gset

\if :have_capture
  insert into mc.dimension (name) values ('dbcraft:terrain') on conflict do nothing;
  delete from mc.chunk where dimension = 'dbcraft:terrain';
  \copy mc.chunk (dimension, cx, cz, hm_motion_blocking, hm_motion_blocking_no_leaves, hm_world_surface, dirty) from program 'python3 tools/import_chunk_capture.py chunks'
  \copy mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data) from program 'python3 tools/import_chunk_capture.py sections'
  \copy mc.chunk_light (dimension, cx, cz, idx, sky_kind, sky, block_kind, block) from program 'python3 tools/import_chunk_capture.py light'
  \copy mc.block_entity (dimension, cx, cz, x, y, z, type, nbt) from program 'python3 tools/import_chunk_capture.py entities'

  select t.is_true('loaded real terrain', (select count(*) from mc.chunk where dimension = 'dbcraft:terrain') >= 25);
  select t.eq('24 sections per chunk', (select count(*) from mc.chunk_section where dimension = 'dbcraft:terrain')::int, 24 * (select count(*) from mc.chunk where dimension = 'dbcraft:terrain')::int);
  select t.is_true('the capture covers palettes of 4, 5, 6 and 7 bits and single-value sections',
                   (select array_agg(distinct bits order by bits) from mc.chunk_section where dimension = 'dbcraft:terrain' and bits <= 7) @> array[0, 4, 5, 6, 7]::smallint[]);
  select t.is_true('the capture has block entities', (select count(*) from mc.block_entity where dimension = 'dbcraft:terrain') > 0);

  -- A. the encoder: every captured packet byte for byte (heightmap entries in our fixed order)
  create temp table enc as
    select e.cx, e.cz, encode(proto.frame(mc.chunk_packet_id(), mc.chunk_packet_body('dbcraft:terrain', e.cx, e.cz)), 'hex') = e.framed as same
    from expected e;
  select t.eq('terrain: every captured chunk re-encodes to identical bytes', (select count(*) from enc where not same)::int, 0);
  do $d$ begin
      raise notice 'terrain oracle: % of % chunks byte-identical (% sections, % palette sections, % block entities)',
          (select count(*) from enc where same), (select count(*) from enc), (select count(*) from mc.chunk_section where dimension = 'dbcraft:terrain'),
          (select count(*) from mc.chunk_section where dimension = 'dbcraft:terrain' and bits > 0), (select count(*) from mc.block_entity where dimension = 'dbcraft:terrain');
  end $d$;

  -- B. block_count / fluid_count: our name-based classification against vanilla's counts, section by section
  create temp table counts as
    select s.cx, s.cz, s.sy, s.block_count, s.fluid_count,
           (select count(*) from mc.section_blocks(s))::int as my_blocks,
           (select count(*) from mc.section_blocks(s) b where mc.has_fluid(b.block))::int as my_fluids
    from mc.chunk_section s where s.dimension = 'dbcraft:terrain';
  select t.eq('block_count: non-air classification agrees with vanilla in every section', (select count(*) from counts where block_count <> my_blocks)::int, 0);
  select t.eq('fluid_count: fluid classification agrees with vanilla in every section', (select count(*) from counts where fluid_count <> my_fluids)::int, 0);
  select t.is_true('fluid sections exist in the capture (the check above is not vacuous)', (select count(*) from counts where fluid_count > 0) > 5);

  -- C. heightmaps recomputed from the loaded sections against the captured ones
  create temp table hmcmp as
    select c.cx, c.cz,
           (select count(*) from unnest(c.hm_world_surface, h.world_surface) u(a, b) where a <> b)::int as ws_diff,
           (select count(*) from unnest(c.hm_motion_blocking, h.motion_blocking) u(a, b) where a <> b)::int as mb_diff,
           (select count(*) from unnest(c.hm_motion_blocking_no_leaves, h.motion_blocking_no_leaves) u(a, b) where a <> b)::int as nl_diff
    from mc.chunk c cross join lateral mc.compute_heightmaps(c.dimension, c.cx, c.cz) h where c.dimension = 'dbcraft:terrain';
  select t.eq('heightmaps: WORLD_SURFACE is exact on real terrain', (select sum(ws_diff) from hmcmp)::int, 0);
  select t.is_true('heightmaps: MOTION_BLOCKING approximation is within 2% of columns', (select sum(mb_diff) from hmcmp) <= 0.02 * 256 * (select count(*) from hmcmp));
  select t.is_true('heightmaps: MOTION_BLOCKING_NO_LEAVES approximation is within 2% of columns', (select sum(nl_diff) from hmcmp) <= 0.02 * 256 * (select count(*) from hmcmp));
  do $d$ begin
      raise notice 'terrain heightmaps: % of % columns differ for WORLD_SURFACE, % for MOTION_BLOCKING, % for MOTION_BLOCKING_NO_LEAVES',
          (select sum(ws_diff) from hmcmp), (select count(*) * 256 from hmcmp), (select sum(mb_diff) from hmcmp), (select sum(nl_diff) from hmcmp);
  end $d$;

  -- D. light: the straight-down model against vanilla's engine.  Informational, not asserted: horizontal spreading and cross-chunk light are not modelled.
  create temp table captured_light as select dimension, cx, cz, idx, sky_kind, sky from mc.chunk_light where dimension = 'dbcraft:terrain';
  select count(*) as relit from (select mc.compute_light('dbcraft:terrain', cx, cz) from mc.chunk where dimension = 'dbcraft:terrain') q \gset
  do $d$ begin
      raise notice 'terrain sky light: % of % captured sky layers identical to the straight-down model (layers present in both: %)',
          (select count(*) from captured_light a join mc.chunk_light b using (dimension, cx, cz, idx) where a.sky_kind is not distinct from b.sky_kind and a.sky is not distinct from b.sky),
          (select count(*) from captured_light where sky_kind is not null),
          (select count(*) from captured_light a join mc.chunk_light b using (dimension, cx, cz, idx) where a.sky_kind is not null and b.sky_kind is not null);
  end $d$;
  -- compute_light rewrote the light rows; restore the captured ones so later checks see vanilla's data
  delete from mc.chunk_light where dimension = 'dbcraft:terrain';
  \copy mc.chunk_light (dimension, cx, cz, idx, sky_kind, sky, block_kind, block) from program 'python3 tools/import_chunk_capture.py light'

  -- E. compaction on real sections keeps every block (palette sections of every width), and the chunks still encode
  create temp table before_compact as
    select s.cx, s.cz, s.sy, md5(array_to_string(array(select b.block from mc.section_blocks(s, true) b order by (b.y - s.sy * 16) * 256 + (b.z - s.cz * 16) * 16 + (b.x - s.cx * 16)), ',')) as h
    from mc.chunk_section s where s.dimension = 'dbcraft:terrain' and s.bits > 0;
  select count(*) as compacted from (select mc.compact_section('dbcraft:terrain', cx, sy, cz) from before_compact) q \gset
  create temp table after_compact as
    select s.cx, s.cz, s.sy, md5(array_to_string(array(select x.block from mc.section_blocks(s, true) x order by (x.y - s.sy * 16) * 256 + (x.z - s.cz * 16) * 16 + (x.x - s.cx * 16)), ',')) as h
    from mc.chunk_section s where s.dimension = 'dbcraft:terrain' and (s.cx, s.cz, s.sy) in (select cx, cz, sy from before_compact);
  select t.eq('compact_section kept every block of every real palette section', (select count(*) from before_compact b join after_compact a using (cx, cz, sy) where a.h <> b.h)::int, 0);
  select t.eq('only sections that were entirely air disappeared', (select count(*) from before_compact b join counts c using (cx, cz, sy)
                where not exists (select 1 from after_compact a where (a.cx, a.cz, a.sy) = (b.cx, b.cz, b.sy)) and c.block_count > 0)::int, 0);
  select t.is_true('compaction reached many real sections', :compacted > 400);
\else
  do $d$ begin raise notice 'SKIPPED terrain oracle: no terrain capture at /tmp/dbcraft-fixtures/terrain_nocomp.jsonl (see tools/capture_vanilla.py and docs/WORLD.md)'; end $d$;
\endif
