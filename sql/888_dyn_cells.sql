-- World dynamics, part 9: a faster mc.cells_positions (sql/850).
--
-- The engine records each block it changes as a one-position 'cells' event (sql/884: vanilla's setBlock sends no break effect, the broadcast sends one for every 'block' event that
-- turns a block into air), and the broadcast (sql/432) expands every cells event with mc.cells_positions.  The version of sql/850 scans all 4,096 bits of the bit map with a cross join
-- of three generate_series, about 0.4 ms for every event: a flow that changes thousands of blocks a tick spent more time expanding bit maps than simulating.  This one visits only the
-- bytes that are not zero (512 probes, then the bits of those bytes); the result is the same array in the same order (/fill order: z, then y, then x).
create or replace function mc.cells_positions(c bytea) returns int[] language plpgsql immutable parallel safe as $$
declare n int := bit_count(c); off int; t bytea; rest bytea := c; skip int := 0; b int; k int; i int; keys int[] := '{}'; kn int := 0;
begin
    if n = 0 then return '{}'; end if;
    if n <= 32 then
        -- sparse maps (ONE changed position is the commonest event of a tick that moves fluids: 19,000 of them in a big flow; the set-based form below costs 40 us each, a scan of 512 bytes
        -- whatever the map holds): the next non-zero byte is found by trimming zero bytes from the front (C speed), its bits are read, then the rest
        loop
            t := ltrim(rest, '\x00'::bytea);
            exit when octet_length(t) = 0;
            off := skip + (octet_length(rest) - octet_length(t));
            b := get_byte(c, off);
            for k in 0 .. 7 loop
                if ((b >> k) & 1) = 1 then
                    i := off * 8 + k;                                                                         -- storage index y << 8 | z << 4 | x
                    kn := kn + 1; keys[kn] := (((i >> 4) & 15) << 8) | ((i >> 8) << 4) | (i & 15);          -- sort key z, y, x: the order of a /fill
                end if;
            end loop;
            skip := off + 1; rest := substring(c from skip + 1);
        end loop;
        if kn = 1 then i := keys[1]; return array[((i & 15) << 8) | ((i >> 8) << 4) | ((i >> 4) & 15)]; end if;
        return array(select ((u.s & 15) << 8) | ((u.s >> 8) << 4) | ((u.s >> 4) & 15) from unnest(keys) u(s) order by u.s);
    end if;
    return (select coalesce(array_agg((b.x << 8) | (b.z << 4) | b.y order by b.z, b.y, b.x), '{}')
              from (select (s.i & 15) as x, ((s.i >> 4) & 15) as z, (s.i >> 8) as y
                      from (select nb.b * 8 + k.k as i from (select g as b from generate_series(0, 511) g where get_byte(c, g) <> 0) nb, generate_series(0, 7) k(k)
                             where ((get_byte(c, nb.b) >> k.k) & 1) = 1) s) b);
end $$;
