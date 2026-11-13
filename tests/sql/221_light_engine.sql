-- The light engine (sql/221 .. 228, docs/LIGHT.md): sky and block light of vanilla's engine from the stored blocks, incremental updates, the tick step.
-- Needs the light reference data (tools/gen_light.sh, tools/load_light.py); skips, loudly, without it.  The comparison with the real vanilla server's light is
-- tests/light/compare_edits.py and tests/light/e2e_light.sh (they need a vanilla server and are not part of this suite).
\! python3 tools/load_world_ref.py
select mc.light_ready() as ready \gset
\if :ready
  delete from mc.light_dirty;
  insert into mc.dimension (name) values ('dbcraft:lf'), ('dbcraft:ln');
  insert into mc.flat_layer (dimension, y, block) values ('dbcraft:lf', -64, 'minecraft:bedrock'), ('dbcraft:lf', -63, 'minecraft:dirt'), ('dbcraft:lf', -62, 'minecraft:dirt'), ('dbcraft:lf', -61, 'minecraft:grass_block');
  select mc.generate_flat_area('dbcraft:lf', -3, -3, 3, 3);

  -- the uniform fast path is exact: the engine gives the same rows
  select t.is_true('a flat 3 x 3 area is uniform', mc.light_flat_ok('dbcraft:lf', 0, 0));
  create temp table flat_rows as select cx, cz, idx, sky_kind, sky, block_kind, block from mc.chunk_light where dimension = 'dbcraft:lf' and cx between -1 and 1 and cz between -1 and 1;
  select mc.light_region('dbcraft:lf', array[-1, -1, -1, 0, 0, 0, 1, 1, 1], array[-1, 0, 1, -1, 0, 1, -1, 0, 1]);
  select t.eq('the engine and the straight-down model agree on a flat world, every layer of 9 chunks',
              (select count(*)::int from flat_rows a join mc.chunk_light b on b.dimension = 'dbcraft:lf' and (b.cx, b.cz, b.idx) = (a.cx, a.cz, a.idx)
                where (a.sky_kind, a.sky, a.block_kind, a.block) is not distinct from (b.sky_kind, b.sky, b.block_kind, b.block)), (select count(*)::int from flat_rows));
  select t.eq('...and no layers appeared or went', (select count(*)::int from mc.chunk_light where dimension = 'dbcraft:lf' and cx between -1 and 1 and cz between -1 and 1), (select count(*)::int from flat_rows));
  select t.eq('sky light above the grass is 15, below the surface 0', mc.light_at('dbcraft:lf', 5, -60, 5, 'sky') * 100 + mc.light_at('dbcraft:lf', 5, -62, 5, 'sky'), 1500);
  select t.eq('layer 0 (below the world) is the empty form', (select sky_kind from mc.chunk_light where dimension = 'dbcraft:lf' and cx = 0 and cz = 0 and idx = 0), 'empty');

  -- block light: a torch (14) falls by one per cell, through air only, across chunk borders; the grass block under it stays dark
  select mc.set_block('dbcraft:lf', 8, -60, 8, 'minecraft:torch');
  select mc.set_block('dbcraft:lf', 15, -60, 24, 'minecraft:torch');
  select t.eq('the queue holds the two torches', (select count(*)::int from mc.light_dirty where dimension = 'dbcraft:lf'), 2);
  select mc.light_step(0);
  select t.eq('the torch cell holds 14', mc.light_at('dbcraft:lf', 8, -60, 8), 14);
  select t.eq('three cells away: 11; four cells away (one up, one east, two south): 10', mc.light_at('dbcraft:lf', 11, -60, 8) * 100 + mc.light_at('dbcraft:lf', 9, -59, 10), 1110);
  select t.eq('13 cells away: 1, 14 away: 0', mc.light_at('dbcraft:lf', 21, -60, 8) * 10 + mc.light_at('dbcraft:lf', 22, -60, 8), 10);
  select t.eq('the grass block under the torch holds no light', mc.light_at('dbcraft:lf', 8, -61, 8), 0);
  select t.eq('the other torch lights the next chunk (x = 16 is chunk 1): 13', mc.light_at('dbcraft:lf', 16, -60, 24), 13);
  select t.is_true('the queue is empty after the step', not exists (select 1 from mc.light_dirty));
  select t.is_true('a chunk that was lit again got a new version and a current packet', (select not dirty from mc.chunk where dimension = 'dbcraft:lf' and cx = 0 and cz = 0));
  -- the same state from scratch
  create temp table inc_rows as select cx, cz, idx, sky_kind, sky, block_kind, block from mc.chunk_light where dimension = 'dbcraft:lf' and cx between -1 and 1 and cz between -1 and 2;
  select mc.light_region('dbcraft:lf', array[-1, -1, -1, -1, 0, 0, 0, 0, 1, 1, 1, 1], array[-1, 0, 1, 2, -1, 0, 1, 2, -1, 0, 1, 2]);
  select t.eq('incremental light after two torches equals light from scratch',
              (select count(*)::int from inc_rows a join mc.chunk_light b on b.dimension = 'dbcraft:lf' and (b.cx, b.cz, b.idx) = (a.cx, a.cz, a.idx)
                where (a.sky_kind, a.sky, a.block_kind, a.block) is distinct from (b.sky_kind, b.sky, b.block_kind, b.block)), 0);
  -- removing a torch takes its light away
  select mc.set_block('dbcraft:lf', 8, -60, 8, 'minecraft:air');
  select mc.light_step(0);
  select t.eq('the torch removed: its cells are dark again', mc.light_at('dbcraft:lf', 8, -60, 8) + mc.light_at('dbcraft:lf', 9, -60, 8), 0);
  -- an edit that changes no light property is not queued (dirt -> stone: both opaque, neither emits)
  select count(*) as q0 from mc.light_dirty where effect > 0 \gset
  select mc.set_block('dbcraft:lf', 3, -62, 3, 'minecraft:stone');
  select t.eq('dirt -> stone is queued as one that cannot change light (effect 0)', (select count(*)::int from mc.light_dirty where effect > 0), :q0);
  select mc.set_block('dbcraft:lf', 3, -62, 3, 'minecraft:air');
  select t.eq('dirt -> air changes sky and block light (effect 3)', (select count(*)::int from mc.light_dirty where effect = 3), :q0 + 1);
  select mc.set_block('dbcraft:lf', 3, -62, 3, 'minecraft:dirt');
  select mc.light_step(0);

  -- sky light under a roof: the cells in the middle get light from the open sides, 1 less per cell
  select mc.fill('dbcraft:lf', 7, -58, 7, 9, -58, 9, 'minecraft:stone');
  select mc.light_step(0);
  select t.eq('under the roof: 14 next to the open side, 13 in the middle', mc.light_at('dbcraft:lf', 7, -59, 8, 'sky') * 100 + mc.light_at('dbcraft:lf', 8, -59, 8, 'sky'), 1413);
  select t.eq('on the roof: 15', mc.light_at('dbcraft:lf', 8, -57, 8, 'sky'), 15);
  select t.eq('the cell above the grass under the roof center holds 13 as well', mc.light_at('dbcraft:lf', 8, -60, 8, 'sky'), 13);

  -- terrain (the seeded noise generator): water, slopes; light computed by the generator in one region
  update mc.dimension set generator = 'dbcraft:noise' where name = 'dbcraft:ln';
  select mc.generate_flat_area('dbcraft:ln', -2, -2, 2, 2);
  select t.is_true('noise terrain has partial sky layers', (select count(*) from mc.chunk_light where dimension = 'dbcraft:ln' and sky_kind = 'data' and sky <> decode(repeat('ff', 2048), 'hex')) > 5);
  select t.is_true('the light of the generated chunks is current', not exists (select 1 from mc.chunk where dimension = 'dbcraft:ln' and dirty));

  -- random edits: the incremental update gives what a full relight gives (the same chunks, after every edit)
  do $$
  declare
      i int; x int; y int; z int; b text; r int; qx int; qz int; ndiff int; bad int := 0;
      blocks text[] := array['minecraft:air', 'minecraft:stone', 'minecraft:torch', 'minecraft:glowstone', 'minecraft:water', 'minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]',
                             'minecraft:glass', 'minecraft:lava', 'minecraft:oak_slab[type=bottom,waterlogged=false]', 'minecraft:oak_slab[type=top,waterlogged=false]',
                             'minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]', 'minecraft:dirt', 'minecraft:air', 'minecraft:air', 'minecraft:stone'];
  begin
      perform setseed(0.31);
      create temp table if not exists sv as select * from mc.chunk_light limit 0;
      for i in 1 .. 14 loop
          x := (random() * 28 - 14)::int; z := (random() * 28 - 14)::int;
          select hm_world_surface[(x & 15) + 16 * (z & 15) + 1] - 65 into y from mc.chunk where dimension = 'dbcraft:ln' and cx = x >> 4 and cz = z >> 4;
          y := y + (random() * 16 - 12)::int;
          b := blocks[1 + (random() * (cardinality(blocks) - 1))::int];
          perform mc.set_block('dbcraft:ln', x, y, z, b);
          r := mc.light_update('dbcraft:ln', array[x], array[y], array[z]);
          qx := x >> 4; qz := z >> 4;
          if r < 0 then perform mc.light_region('dbcraft:ln', array[qx - 1, qx - 1, qx - 1, qx, qx, qx, qx + 1, qx + 1, qx + 1], array[qz - 1, qz, qz + 1, qz - 1, qz, qz + 1, qz - 1, qz, qz + 1]); commit; continue; end if;
          delete from sv;
          insert into sv select * from mc.chunk_light l where l.dimension = 'dbcraft:ln' and l.cx between qx - 1 and qx + 1 and l.cz between qz - 1 and qz + 1;
          perform mc.light_region('dbcraft:ln', array[qx - 1, qx - 1, qx - 1, qx, qx, qx, qx + 1, qx + 1, qx + 1], array[qz - 1, qz, qz + 1, qz - 1, qz, qz + 1, qz - 1, qz, qz + 1]);
          select count(*) into ndiff from sv a join mc.chunk_light b using (dimension, cx, cz, idx) where (a.sky, a.block) is distinct from (b.sky, b.block);
          if ndiff > 0 then bad := bad + 1; raise warning 'edit % % at %,%,%: % layers differ', i, b, x, y, z, ndiff; end if;
          commit;
      end loop;
      perform t.eq('14 random edits: the incremental light equals the full relight', bad, 0);
  end $$;

  -- the packet of a light change: the marks, the body
  do $$
  declare r int; body bytea; o int; n int; masks int[] := '{}'; x int; z int; v int; k int;
  begin
      perform mc.set_block('dbcraft:lf', 40, -60, 40, 'minecraft:glowstone');
      r := mc.light_update('dbcraft:lf', array[40], array[-60], array[40]);
      perform t.is_true('the glowstone changed some layers', r > 0);
      perform mc.light_marks('dbcraft:lf');
      perform t.is_true('the marks list chunk (2, 2), layer 2 (the section above the grass)', exists (select 1 from lw_mark where cx = 2 and cz = 2 and idx = 2 and blk));
      body := mc.light_update_body('dbcraft:lf', 2, 2);
      select val, nxt into x, o from proto.varint_read(body, 0);
      select val, nxt into z, o from proto.varint_read(body, o);
      perform t.eq('the body starts with the chunk coordinates', x * 100 + z, 202);
      -- sky mask, block mask, empty sky, empty block: VarInt byte counts then bytes
      for k in 1 .. 4 loop
          select val, nxt into n, o from proto.varint_read(body, o);
          v := case when n = 0 then 0 else get_byte(body, o) end; o := o + n; masks := masks || v;
      end loop;
      perform t.is_true('the block light of layer 2 is in the block set (bit 2)', (masks[2] & 4) = 4);
      perform t.is_true('the layers outside the marks are not in it', (masks[2] & 128) = 0);
  end $$;
  delete from mc.light_dirty;
\else
  do $$ begin raise notice 'SKIP: no light reference data (tools/gen_light.sh, tools/load_light.py): the light engine tests were not run'; end $$;
\endif
