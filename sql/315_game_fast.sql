-- Game module, part 2b: inlinable versions of the hot codec helpers.
--
-- Why this file exists: a LANGUAGE sql function is only inlined into its caller when its body is a single expression (no FROM / WITH) and any argument it uses
-- more than once is cheap.  The first versions in sql/020_proto.sql and sql/310_game_packets.sql used a FROM subselect, so every call ran a full executor
-- start-up.  Measured on this machine (tests/bench/game, docs/GAME.md): 20,000 move packets took 10.8 s, float decoding cost 33 us per number.
-- The functions below return exactly the same bytes/values (tests/sql/10_proto.sql checks that); they only evaluate faster.
-- Loaded after 310 so these definitions replace the earlier ones.
-- Careful: in Postgres << >> & | all share ONE precedence level (left to right), so every shifted term is parenthesised.

-- the general VarInt routine (the original implementation, kept for large values and negatives)
create or replace function proto.varint_slow(n int) returns bytea language sql immutable parallel safe as $$
  select case
    when u < 128        then set_byte('\x00'::bytea, 0, u::int)
    when u < 16384      then set_byte(set_byte('\x0000'::bytea, 0, ((u & 127) | 128)::int), 1, (u >> 7)::int)
    when u < 2097152    then set_byte(set_byte(set_byte('\x000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (u >> 14)::int)
    when u < 268435456  then set_byte(set_byte(set_byte(set_byte('\x00000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (((u >> 14) & 127) | 128)::int), 3, (u >> 21)::int)
    else set_byte(set_byte(set_byte(set_byte(set_byte('\x0000000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (((u >> 14) & 127) | 128)::int), 3, (((u >> 21) & 127) | 128)::int), 4, (u >> 28)::int)
  end
  from (select n::bigint & 4294967295 as u) s $$;

-- VarInt: the common sizes (0..16383, covering packet ids, entity ids and lengths) are direct expressions
create or replace function proto.varint(n int) returns bytea language sql immutable parallel safe as $$
  select case when n >= 0 and n < 128 then set_byte('\x00'::bytea, 0, n)
              when n >= 0 and n < 16384 then set_byte(set_byte('\x0000'::bytea, 0, (n & 127) | 128), 1, n >> 7)
              else proto.varint_slow(n) end $$;

-- frame: packet ids below 128 take one byte (all but the last few clientbound play ids)
create or replace function proto.frame(packet_id int, body bytea) returns bytea language sql immutable parallel safe as $$
  select case when packet_id >= 0 and packet_id < 128 then proto.varint(octet_length(body) + 1) || set_byte('\x00'::bytea, 0, packet_id) || body
              else proto.varint(octet_length(proto.varint_slow(packet_id)) + octet_length(body)) || proto.varint_slow(packet_id) || body end $$;

-- packet id lookups as scalar subselects: inlinable, and evaluated once per query when the name is a constant (an InitPlan)
create or replace function mc.pid(pname text) returns int language sql stable parallel safe as $$
  select (select protocol_id from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:' || pname) $$;
create or replace function mc.sid(pname text) returns int language sql stable parallel safe as $$
  select (select protocol_id from ref.packet where state = 'play' and direction = 'serverbound' and name = 'minecraft:' || pname) $$;

-- IEEE 754 double as one expression: sign bit, 11-bit exponent e, 52-bit mantissa m.  value = (2^52 + m) * 2^(e - 1075); subnormals (e = 0): m * 2^-1074.
create or replace function proto.f64_read(b bytea, off int default 0) returns float8 language sql immutable parallel safe as $$
  select case
    when (((get_byte(b, off) & 127) << 4) | (get_byte(b, off + 1) >> 4)) = 2047 then
      case when (((get_byte(b, off + 1) & 15)::bigint << 48) | (get_byte(b, off + 2)::bigint << 40) | (get_byte(b, off + 3)::bigint << 32) | (get_byte(b, off + 4)::bigint << 24)
                 | (get_byte(b, off + 5)::bigint << 16) | (get_byte(b, off + 6)::bigint << 8) | get_byte(b, off + 7)::bigint) = 0
           then (case when get_byte(b, off) >= 128 then '-Infinity' else 'Infinity' end)::float8 else 'NaN'::float8 end
    else (case when get_byte(b, off) >= 128 then -1.0 else 1.0 end)::float8
         * ((case when (((get_byte(b, off) & 127) << 4) | (get_byte(b, off + 1) >> 4)) = 0 then 0::bigint else 4503599627370496::bigint end)
            + (((get_byte(b, off + 1) & 15)::bigint << 48) | (get_byte(b, off + 2)::bigint << 40) | (get_byte(b, off + 3)::bigint << 32) | (get_byte(b, off + 4)::bigint << 24)
               | (get_byte(b, off + 5)::bigint << 16) | (get_byte(b, off + 6)::bigint << 8) | get_byte(b, off + 7)::bigint))::float8
         * power(2::float8, (case when (((get_byte(b, off) & 127) << 4) | (get_byte(b, off + 1) >> 4)) = 0 then -1074
                                  else (((get_byte(b, off) & 127) << 4) | (get_byte(b, off + 1) >> 4)) - 1075 end)::float8)
  end $$;

-- IEEE 754 float: sign, 8-bit exponent e, 23-bit mantissa m.  value = (2^23 + m) * 2^(e - 150); subnormals: m * 2^-149.
create or replace function proto.f32_read(b bytea, off int default 0) returns real language sql immutable parallel safe as $$
  select (case
    when (((get_byte(b, off) & 127) << 1) | (get_byte(b, off + 1) >> 7)) = 255 then
      case when (((get_byte(b, off + 1) & 127) << 16) | (get_byte(b, off + 2) << 8) | get_byte(b, off + 3)) = 0
           then (case when get_byte(b, off) >= 128 then '-Infinity' else 'Infinity' end)::float8 else 'NaN'::float8 end
    else (case when get_byte(b, off) >= 128 then -1.0 else 1.0 end)::float8
         * ((case when (((get_byte(b, off) & 127) << 1) | (get_byte(b, off + 1) >> 7)) = 0 then 0 else 8388608 end)
            + (((get_byte(b, off + 1) & 127) << 16) | (get_byte(b, off + 2) << 8) | get_byte(b, off + 3)))::float8
         * power(2::float8, (case when (((get_byte(b, off) & 127) << 1) | (get_byte(b, off + 1) >> 7)) = 0 then -149
                                  else (((get_byte(b, off) & 127) << 1) | (get_byte(b, off + 1) >> 7)) - 150 end)::float8)
  end)::real $$;
