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

-- The four planes of a stored array (the inverse): hex digit planes by translate, then the layout change of a row (the array's bytes of a row come in the order
-- of x = 0 .. 15 with the odd cell in the high nibble; layout M wants x = 15 .. 0).
create or replace function mc.light_planes(p_arr bytea, out c3 bit(4096), out c2 bit(4096), out c1 bit(4096), out c0 bit(4096)) language plpgsql immutable parallel safe as $$
declare
    h  text := encode(p_arr, 'hex');                                                -- per byte: high nibble (odd x) first
    w  bit(16384);
    t  text;
begin
    -- turn the array's rows (64 bits = 8 bytes) around: the bytes of a row become x = 15, 14 .. 0 order
    w := ('x' || h)::bit(16384);
    w := ((w & mc.lk_bs(8)) << 8) | ((w >> 8) & mc.lk_bs(8));
    w := ((w & mc.lk_bs(16)) << 16) | ((w >> 16) & mc.lk_bs(16));
    w := ((w & mc.lk_bs(32)) << 32) | ((w >> 32) & mc.lk_bs(32));
    t := translate(w::text, '01', '01');                                              -- (w as text is 16384 binary digits, 4 per cell: c3 c2 c1 c0)
    -- plane k of cell p is character 4 p + (3 - k) of t
    c3 := regexp_replace(t, '(.)...', '\1', 'g')::bit(4096);
    c2 := regexp_replace(t, '.(.)..', '\1', 'g')::bit(4096);
    c1 := regexp_replace(t, '..(.).', '\1', 'g')::bit(4096);
    c0 := regexp_replace(t, '...(.)', '\1', 'g')::bit(4096);
end $$;
