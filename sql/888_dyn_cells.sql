-- World dynamics, part 9: a faster mc.cells_positions (sql/850).
--
-- The engine records each block it changes as a one-position 'cells' event (sql/884: vanilla's setBlock sends no break effect, the broadcast sends one for every 'block' event that
-- turns a block into air), and the broadcast (sql/432) expands every cells event with mc.cells_positions.  The version of sql/850 scans all 4,096 bits of the bit map with a cross join
-- of three generate_series, about 0.4 ms for every event: a flow that changes thousands of blocks a tick spent more time expanding bit maps than simulating.  This one visits only the
-- bytes that are not zero (512 probes, then the bits of those bytes); the result is the same array in the same order (/fill order: z, then y, then x).
create or replace function mc.cells_positions(c bytea) returns int[] language sql immutable parallel safe as $$
  select coalesce(array_agg((b.x << 8) | (b.z << 4) | b.y order by b.z, b.y, b.x), '{}')
    from (select (s.i & 15) as x, ((s.i >> 4) & 15) as z, (s.i >> 8) as y
            from (select nb.b * 8 + k.k as i from (select g as b from generate_series(0, 511) g where get_byte(c, g) <> 0) nb, generate_series(0, 7) k(k)
                   where ((get_byte(c, nb.b) >> k.k) & 1) = 1) s) b $$;
