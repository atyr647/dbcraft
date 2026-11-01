-- mc.blocks, rewritten so that a filter on x, y, z is applied BEFORE any section is unpacked (docs/PERF-SCALE.md).
--
-- The first version (sql/210) unpacked all 4,096 entries of every section with a set-returning function and filtered afterwards, so
--   select * from mc.blocks where x = 1 and y = -61 and z = 2
-- cost about 4 ms per stored section (3.98 s per 1,000 sections; about 800 s at 200,000 sections).  Here the three coordinates are plain join columns
-- (section origin + a 0..15 series per axis), so each filter keeps one of 16 values per axis and the block is looked up only for the survivors.
-- It is still a scan of the section table (the planner cannot invert x = cx * 16 + lx), but the cost per section drops from milliseconds to microseconds.
-- To use the section index as well, add the section coordinates that are now exposed as columns:
--   select * from mc.blocks where cx = 0 and cz = 0 and sy = -4 and x = 1 and y = -61 and z = 2        -- one index lookup
-- The three extra columns come last so that CREATE OR REPLACE VIEW keeps the INSTEAD OF triggers of sql/210 and the old columns unchanged.
create or replace view mc.blocks as
  select s.dimension,
         s.cx * 16 + lx.v as x,
         s.sy * 16 + ly.v as y,
         s.cz * 16 + lz.v as z,
         b.block,
         s.cx, s.cz, s.sy
  from mc.chunk_section s
  cross join generate_series(0, 15) lx(v)
  cross join generate_series(0, 15) ly(v)
  cross join generate_series(0, 15) lz(v)
  cross join lateral (select case when cardinality(s.palette) = 0
                                  then mc.state_name(mc.entry_at(s.bits, s.data, (ly.v << 8) | (lz.v << 4) | lx.v))
                                  else s.palette[mc.entry_at(s.bits, s.data, (ly.v << 8) | (lz.v << 4) | lx.v) + 1] end as block
                      offset 0) b                                   -- OFFSET 0: look the block up once per row, after the coordinate filters
  where s.block_count > 0 and not mc.is_air(b.block);               -- sections without a non-air block are skipped before any unpacking
