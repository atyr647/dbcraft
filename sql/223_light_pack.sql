-- Light engine, part 3: from level bit-planes to the 2,048-byte nibble arrays of the protocol, and back.  See docs/LIGHT.md.
--
-- A section's light is held as four bit-planes c3 c2 c1 c0 (bit(4096) each, layout M of sql/222): the level of a cell is 8 c3 + 4 c2 + 2 c1 + c0.  The protocol array is
-- one nibble per cell, index (y << 8) | (z << 4) | x, low nibble first.  In layout M a row of 16 cells reads x = 15 .. 0, so spreading each plane to one bit per nibble
-- puts the cells of a row in the order of the byte-swapped 64-bit word of the array: the planes are spread (Morton spread by 4, 12 rounds), merged, byte-swapped
-- inside every 64-bit word and cut into longs.
create or replace function mc.lk_sp(d int) returns bit(16384) language sql immutable parallel safe as $$
  select repeat(repeat('0', 3 * d) || repeat('1', d), 16384 / (4 * d))::bit(16384) $$;
create or replace function mc.lk_z12288() returns bit(12288) language sql immutable parallel safe as $$ select repeat('0', 12288)::bit(12288) $$;
create or replace function mc.lk_bs(w int) returns bit(16384) language sql immutable parallel safe as $$              -- the low w bits of every 2w-bit group
  select repeat(repeat('0', w) || repeat('1', w), 8192 / w)::bit(16384) $$;

-- one plane spread to one bit per nibble: bit p of the plane ends at position 4 p + 3 of the result
create or replace function mc.light_spread4(x bit(4096)) returns bit(16384) language plpgsql immutable parallel safe as $$
declare z bit(16384);
begin
    z := mc.lk_z12288() || x;
    z := (z | (z << 6144)) & mc.lk_sp(2048);
    z := (z | (z << 3072)) & mc.lk_sp(1024);
    z := (z | (z << 1536)) & mc.lk_sp(512);
    z := (z | (z << 768)) & mc.lk_sp(256);
    z := (z | (z << 384)) & mc.lk_sp(128);
    z := (z | (z << 192)) & mc.lk_sp(64);
    z := (z | (z << 96)) & mc.lk_sp(32);
    z := (z | (z << 48)) & mc.lk_sp(16);
    z := (z | (z << 24)) & mc.lk_sp(8);
    z := (z | (z << 12)) & mc.lk_sp(4);
    z := (z | (z << 6)) & mc.lk_sp(2);
    z := (z | (z << 3)) & mc.lk_sp(1);
    return z;
end $$;

-- The 2,048-byte light array of the four planes.
create or replace function mc.light_array(c3 bit(4096), c2 bit(4096), c1 bit(4096), c0 bit(4096)) returns bytea language plpgsql immutable parallel safe as $$
declare y bit(16384);
begin
    y := mc.light_spread4(c0) | (mc.light_spread4(c1) << 1) | (mc.light_spread4(c2) << 2) | (mc.light_spread4(c3) << 3);
    y := ((y & mc.lk_bs(8)) << 8) | ((y >> 8) & mc.lk_bs(8));                      -- reverse the bytes of every 64-bit word
    y := ((y & mc.lk_bs(16)) << 16) | ((y >> 16) & mc.lk_bs(16));
    y := ((y & mc.lk_bs(32)) << 32) | ((y >> 32) & mc.lk_bs(32));
    return (select string_agg(int8send(substring(y from 64 * k + 1 for 64)::bit(64)::bigint), ''::bytea order by k) from generate_series(0, 255) k);
end $$;

-- A uniform array: every cell at one level.
create or replace function mc.light_array_uniform(p_level int) returns bytea language sql immutable parallel safe as $$
  select decode(repeat(to_hex(p_level), 4096), 'hex') $$;

-- The four planes of a stored array (the inverse): one translate() per plane over the hex digits (the array's bytes hold the cell with odd x in the high nibble, so a
-- row of 16 cells reads x = 1, 0, 3, 2 ..), then the 8 pairs of every row are put in the order of layout M (x = 15 .. 0) by three swaps.
create or replace function mc.light_planes(p_arr bytea, out c3 bit(4096), out c2 bit(4096), out c1 bit(4096), out c0 bit(4096)) language plpgsql immutable parallel safe as $$
declare
    h text := encode(p_arr, 'hex');
begin
    c3 := mc.light_rowfix(translate(h, '0123456789abcdef', '0000000011111111')::bit(4096));
    c2 := mc.light_rowfix(translate(h, '0123456789abcdef', '0000111100001111')::bit(4096));
    c1 := mc.light_rowfix(translate(h, '0123456789abcdef', '0011001100110011')::bit(4096));
    c0 := mc.light_rowfix(translate(h, '0123456789abcdef', '0101010101010101')::bit(4096));
end $$;

-- cell order x^1 (the order of a stored array's hex digits) to layout M: reverse the 8 pairs of every 16 cells
create or replace function mc.light_rowfix(x bit(4096)) returns bit(4096) language plpgsql immutable parallel safe as $$
begin
    x := ((x & mc.lk_g(2)) << 2) | ((x >> 2) & mc.lk_g(2));
    x := ((x & mc.lk_g(4)) << 4) | ((x >> 4) & mc.lk_g(4));
    x := ((x & mc.lk_g(8)) << 8) | ((x >> 8) & mc.lk_g(8));
    return x;
end $$;
create or replace function mc.lk_g(w int) returns bit(4096) language sql immutable parallel safe as $$              -- the low w bits of every 2w-bit group
  select repeat(repeat('0', w) || repeat('1', w), 2048 / w)::bit(4096) $$;
