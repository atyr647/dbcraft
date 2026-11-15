-- Codec and pure functions: VarInt, frames, hash2, the terrain generator, section (un)packing, wire blobs, IEEE decoding.
-- Everything here is IMMUTABLE PARALLEL SAFE; the tiny ones are LANGUAGE sql so that the planner inlines them.

------------------------------------------------------------------------------------------------ varint, frames
create function mc.varint(v int) returns bytea language sql immutable parallel safe as $$
  select case
    when v < 128       then set_byte('\x00'::bytea, 0, v)
    when v < 16384     then set_byte(set_byte('\x0000'::bytea, 0, (v & 127) | 128), 1, v >> 7)
    when v < 2097152   then set_byte(set_byte(set_byte('\x000000'::bytea, 0, (v & 127) | 128), 1, ((v >> 7) & 127) | 128), 2, v >> 14)
    when v < 268435456 then set_byte(set_byte(set_byte(set_byte('\x00000000'::bytea, 0, (v & 127) | 128), 1, ((v >> 7) & 127) | 128), 2, ((v >> 14) & 127) | 128), 3, v >> 21)
    else set_byte(set_byte(set_byte(set_byte(set_byte('\x0000000000'::bytea, 0, (v & 127) | 128), 1, ((v >> 7) & 127) | 128), 2, ((v >> 14) & 127) | 128), 3, ((v >> 21) & 127) | 128), 4, v >> 28)
  end $$;

-- varint(len(body)) || body
create function mc.frame(body bytea) returns bytea language sql immutable parallel safe as $$
  select mc.varint(length(body)) || body $$;

------------------------------------------------------------------------------------------------ hash2 / terrain (SPEC 4)
-- 64-bit two's complement arithmetic as in the reference, but without ever overflowing a bigint (PostgreSQL raises on overflow instead of wrapping):
-- only the low 31 bits of each product matter, and they depend only on the low 31 bits of the factors.  ^ is exponentiation in SQL; # is xor.
create function mc.hash2(a bigint, b bigint, s bigint) returns int language sql immutable parallel safe as $$
  select (((((((((a & 2147483647) * 374761393) & 2147483647) + (((b & 2147483647) * 668265263) & 2147483647) + (((s & 2147483647) * 1274126177) & 2147483647)) & 2147483647) # ((((((a & 2147483647) * 374761393) & 2147483647) + (((b & 2147483647) * 668265263) & 2147483647) + (((s & 2147483647) * 1274126177) & 2147483647)) & 2147483647) >> 13)) * 1274126177) & 2147483647) # (((((((((a & 2147483647) * 374761393) & 2147483647) + (((b & 2147483647) * 668265263) & 2147483647) + (((s & 2147483647) * 1274126177) & 2147483647)) & 2147483647) # ((((((a & 2147483647) * 374761393) & 2147483647) + (((b & 2147483647) * 668265263) & 2147483647) + (((s & 2147483647) * 1274126177) & 2147483647)) & 2147483647) >> 13)) * 1274126177) & 2147483647) >> 16))::int $$;

-- Same function for int arguments: |a|,|b|,|s| < 2^31 and the constants are < 2^31, so the three products sum to less than 2^62 and need no pre-masking
-- (PostgreSQL resolves hash2(1, 2, 3) to this overload; bigint arguments take the wrap-safe one above).
create function mc.hash2(a int, b int, s int) returns int language sql immutable parallel safe as $$
  select ((((((a::bigint * 374761393 + b::bigint * 668265263 + s::bigint * 1274126177) & 2147483647) # (((a::bigint * 374761393 + b::bigint * 668265263 + s::bigint * 1274126177) & 2147483647) >> 13)) * 1274126177) & 2147483647) # ((((((a::bigint * 374761393 + b::bigint * 668265263 + s::bigint * 1274126177) & 2147483647) # (((a::bigint * 374761393 + b::bigint * 668265263 + s::bigint * 1274126177) & 2147483647) >> 13)) * 1274126177) & 2147483647) >> 16))::int $$;

create function mc.oct(x int, z int, sh int, seed int) returns int language sql immutable parallel safe as $$
  select ((n.a * (g.c - g.fx) * (g.c - g.fz) + n.b * g.fx * (g.c - g.fz) + n.c * (g.c - g.fx) * g.fz + n.d * g.fx * g.fz) >> (2 * sh))::int
  from (select (1::bigint << sh) c, (x & ((1 << sh) - 1))::bigint fx, (z & ((1 << sh) - 1))::bigint fz, (x >> sh)::bigint gx, (z >> sh)::bigint gz) g,
  lateral (select (mc.hash2(g.gx,     g.gz,     seed) & 4095)::bigint a, (mc.hash2(g.gx + 1, g.gz,     seed) & 4095)::bigint b,
                  (mc.hash2(g.gx,     g.gz + 1, seed) & 4095)::bigint c, (mc.hash2(g.gx + 1, g.gz + 1, seed) & 4095)::bigint d) n $$;

create function mc.height(x int, z int) returns int language sql immutable parallel safe as $$
  select 52 + ((mc.oct(x, z, 6, 1337) * 32) >> 12) + ((mc.oct(x, z, 4, 1338) * 10) >> 12) $$;

-- The 256 column heights of a chunk, index z*16 + x (1-based in SQL).  Each octave's four lattice corners are the same for the whole chunk
-- (a chunk never straddles a lattice cell of size 64 or 16), so 8 hashes cover all 256 columns.
create function mc.chunk_heights(cx int, cz int) returns int[] language sql immutable parallel safe as $$
  select array(
    select 52 + ((o6 * 32) >> 12) + ((o4 * 10) >> 12)
    from (select zz, xx,
                 (c.a6 * (64 - f6x) * (64 - f6z) + c.b6 * f6x * (64 - f6z) + c.c6 * (64 - f6x) * f6z + c.d6 * f6x * f6z) >> 12 as o6,
                 (c.a4 * (16 - xx) * (16 - zz) + c.b4 * xx * (16 - zz) + c.c4 * (16 - xx) * zz + c.d4 * xx * zz) >> 8 as o4
          from generate_series(0, 15) zz, generate_series(0, 15) xx,
               lateral (select (((cx & 3) * 16) + xx)::bigint f6x, (((cz & 3) * 16) + zz)::bigint f6z) f) q
    order by zz, xx)
  from (select (mc.hash2(cx >> 2, cz >> 2, 1337) & 4095)::bigint a6, (mc.hash2((cx >> 2) + 1, cz >> 2, 1337) & 4095)::bigint b6,
               (mc.hash2(cx >> 2, (cz >> 2) + 1, 1337) & 4095)::bigint c6, (mc.hash2((cx >> 2) + 1, (cz >> 2) + 1, 1337) & 4095)::bigint d6,
               (mc.hash2(cx, cz, 1338) & 4095)::bigint a4, (mc.hash2(cx + 1, cz, 1338) & 4095)::bigint b4,
               (mc.hash2(cx, cz + 1, 1338) & 4095)::bigint c4, (mc.hash2(cx + 1, cz + 1, 1338) & 4095)::bigint d4) c $$;

-- ore roll of a stone-zone block and the state it selects
create function mc.ore_r(x int, y int, z int) returns int language sql immutable parallel safe as $$
  select mc.hash2(x + y * 4099, z - y * 7919, 11) % 1024 $$;
create function mc.ore(r int, y int) returns int language sql immutable parallel safe as $$
  select case when r < 10 then 15 when r < 15 and y < 32 then 16 when r = 15 and y < -16 then 17 else 1 end $$;

-- block_at given the column height h (SPEC 4)
create function mc.col_state(x int, y int, z int, h int) returns int language sql immutable parallel safe as $$
  select case
    when y = -64 then 4
    when y > h then case when y <= 62 then 6 else 0 end
    when y = h then case when h <= 63 then 5 else 2 end
    when y >= h - 3 then case when h <= 63 then 5 when y = h - 1 and (mc.hash2(x, z, 7) & 31) = 0 then 14 else 3 end
    else mc.ore(mc.ore_r(x, y, z), y)
  end $$;

create function mc.block_at(x int, y int, z int) returns int language sql immutable parallel safe as $$
  select mc.col_state(x, y, z, mc.height(x, z)) $$;

------------------------------------------------------------------------------------------------ packed longs (SPEC 2)
-- Entry i of a section: vpl = 64 / bits entries per long, entry (i % vpl) at bit (i % vpl) * bits, longs big-endian, so bit p of long n
-- lives in byte n*8 + 7 - p/8.  An entry (<= 8 bits) touches at most two bytes and never leaves its long.
create function mc.entry_get(bits int, data bytea, i int) returns int language sql immutable parallel safe as $$
  select case when bits = 0 then 0 else
    (((get_byte(data, k) | case when k > b then get_byte(data, k - 1) << 8 else 0 end) >> (p & 7)) & ((1 << bits) - 1))
  end
  from (select (i / (64 / bits)) * 8 as b, (i % (64 / bits)) * bits as p) q, lateral (select b + 7 - (p >> 3) as k) r $$;

-- state at section index i (palette lookup included)
create function mc.state_at(pal int[], bits int, data bytea, i int) returns int language sql immutable parallel safe as $$
  select pal[1 + mc.entry_get(bits, data, i)] $$;

create function mc.entry_put(bits int, data bytea, i int, v int) returns bytea language plpgsql immutable parallel safe as $$
declare
    vpl int := 64 / bits;
    b   int := (i / vpl) * 8;
    p   int := (i % vpl) * bits;
    k   int := b + 7 - (p >> 3);
    sh  int := p & 7;
    w   int;
begin
    w := get_byte(data, k);
    if k > b then w := w | (get_byte(data, k - 1) << 8); end if;
    w := (w & ~(((1 << bits) - 1) << sh)) | (v << sh);
    data := set_byte(data, k, w & 255);
    if k > b and sh + bits > 8 then data := set_byte(data, k - 1, (w >> 8) & 255); end if;
    return data;
end $$;

-- all 4096 entries (palette indices); set-based, no loop
create function mc.unpack(bits int, data bytea) returns int[] language sql immutable parallel safe as $$
  select case when bits = 0 then array_fill(0, array[4096]) else array(
    select ((get_byte(data, k) | case when k > b then get_byte(data, k - 1) << 8 else 0 end) >> (p & 7)) & ((1 << bits) - 1)
    from generate_series(0, 4095) i,
         lateral (select (i / (64 / bits)) * 8 as b, (i % (64 / bits)) * bits as p) q,
         lateral (select b + 7 - (p >> 3) as k) r) end $$;

-- entries (1-based array, any length up to 4096) -> packed longs: one bit_or of shifted entries per long, int8send, string_agg
create function mc.pack_entries(entries int[], bits int) returns bytea language sql immutable parallel safe as $$
  select case when bits = 0 then '\x'::bytea else
    (select string_agg(int8send(w), ''::bytea order by k)
       from (select (i - 1) / (64 / bits) as k, bit_or(e::bigint << ((((i - 1) % (64 / bits)) * bits)::int)) as w
               from unnest(entries) with ordinality t(e, i) group by 1) q) end $$;

------------------------------------------------------------------------------------------------ section blob (SPEC 2)
create function mc.section_blob(bc int, bits int, pal int[], data bytea) returns bytea language sql immutable parallel safe as $$
  select int2send(bc::int2) || set_byte('\x00'::bytea, 0, bits)
         || case when bits = 0 then mc.varint(pal[1])
                 else mc.varint(cardinality(pal)) || (select string_agg(mc.varint(p), ''::bytea order by o) from unnest(pal) with ordinality t(p, o)) || data end
         || '\x0000'::bytea $$;

------------------------------------------------------------------------------------------------ IEEE decoding (the inbox carries big-endian doubles and floats)
-- PostgreSQL has no bytea -> float8.  Rebuilding from sign / exponent / mantissa is exact: m / 2^52 and the power of two are exact in a double.
create function mc.f64be(b bytea, off int) returns float8 language sql immutable parallel safe as $$
  select case when t.e = 2047 then (case when t.m = 0 then 'Infinity' else 'NaN' end)::float8
              else (case when t.v < 0 then -1.0::float8 else 1.0::float8 end) *
                   (case when t.e = 0 then (t.m::float8 / 4503599627370496.0) * (2.0::float8 ^ (-1022))
                         else (1.0::float8 + t.m::float8 / 4503599627370496.0) * (2.0::float8 ^ (t.e - 1023)) end) end
  from (select v, ((v >> 52) & 2047)::int as e, v & 4503599627370495 as m
        from (select ('x' || encode(substring(b from off + 1 for 8), 'hex'))::bit(64)::bigint as v) u) t $$;

create function mc.f32be(b bytea, off int) returns float4 language sql immutable parallel safe as $$
  select (case when t.e = 255 then (case when t.m = 0 then 'Infinity' else 'NaN' end)::float8
              else (case when t.v < 0 then -1.0::float8 else 1.0::float8 end) *
                   (case when t.e = 0 then (t.m::float8 / 8388608.0) * (2.0::float8 ^ (-126))
                         else (1.0::float8 + t.m::float8 / 8388608.0) * (2.0::float8 ^ (t.e - 127)) end) end)::float4
  from (select v, ((v >> 23) & 255)::int as e, v & 8388607 as m
        from (select ('x' || encode(substring(b from off + 1 for 4), 'hex'))::bit(32)::int as v) u) t $$;

-- angle(deg) = floor(deg * 256.0 / 360.0) & 255 on the float4 value widened to double
create function mc.angle(deg float4) returns int language sql immutable parallel safe as $$
  select (floor(deg::float8 * 256.0 / 360.0)::bigint & 255)::int $$;

-- bits per entry for a palette of n entries (SPEC 2): 0 for one entry, else max(4, ceillog2(n))
create function mc.bits_for(n int) returns int language sql immutable parallel safe as $$
  select case when n <= 1 then 0 else greatest(4, length(ltrim((n - 1)::bit(32)::text, '0'))) end $$;
