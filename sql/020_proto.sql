-- Wire-format codec.  Pure functions on bytea; offsets are 0-based like get_byte().
-- Hot-path functions are plain LANGUAGE sql so the planner can inline them (7x faster than PL/pgSQL in tests/bench).
-- Readers with two results use OUT parameters: select * from proto.varint_read(b, off).

-- Raised (never constant-folded: it is volatile) on malformed input.
create or replace function proto.bad(msg text) returns bigint language plpgsql volatile as $$
begin raise exception 'protocol error: %', msg using errcode = '22P03'; end $$;

------------------------------------------------------------------------------------------------ VarInt
create or replace function proto.varint(n int) returns bytea language sql immutable parallel safe as $$
  select case
    when u < 128        then set_byte('\x00'::bytea, 0, u::int)
    when u < 16384      then set_byte(set_byte('\x0000'::bytea, 0, ((u & 127) | 128)::int), 1, (u >> 7)::int)
    when u < 2097152    then set_byte(set_byte(set_byte('\x000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (u >> 14)::int)
    when u < 268435456  then set_byte(set_byte(set_byte(set_byte('\x00000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (((u >> 14) & 127) | 128)::int), 3, (u >> 21)::int)
    else set_byte(set_byte(set_byte(set_byte(set_byte('\x0000000000'::bytea, 0, ((u & 127) | 128)::int), 1, (((u >> 7) & 127) | 128)::int), 2, (((u >> 14) & 127) | 128)::int), 3, (((u >> 21) & 127) | 128)::int), 4, (u >> 28)::int)
  end
  from (select n::bigint & 4294967295 as u) s
$$;

-- Returns (NULL, NULL) when the buffer ends inside the VarInt ("need more bytes").
-- Rejects: longer than 5 bytes, a fifth byte above 15, and overlong forms (a multi-byte value whose last group is 0), like adacraft's decoder.
create or replace function proto.varint_read(b bytea, off int default 0, out val int, out nxt int)
language sql immutable parallel safe as $$
  with x as (select
      (case when off     < length(b) then get_byte(b, off)     end)::bigint as b0,
      (case when off + 1 < length(b) then get_byte(b, off + 1) end)::bigint as b1,
      (case when off + 2 < length(b) then get_byte(b, off + 2) end)::bigint as b2,
      (case when off + 3 < length(b) then get_byte(b, off + 3) end)::bigint as b3,
      (case when off + 4 < length(b) then get_byte(b, off + 4) end)::bigint as b4),
  y as (select *, case
      when b0 is null then null  when b0 < 128 then 1
      when b1 is null then null  when b1 < 128 then 2
      when b2 is null then null  when b2 < 128 then 3
      when b3 is null then null  when b3 < 128 then 4
      when b4 is null then null  when b4 < 16  then 5
      else proto.bad('VarInt too long or fifth byte out of range')::int end as n from x),
  z as (select n, case
      when n > 1 and (case n when 2 then b1 when 3 then b2 when 4 then b3 else b4 end) = 0 then proto.bad('overlong VarInt')
      else case n when 1 then b0
                  when 2 then (b0 & 127) | (b1 << 7)
                  when 3 then (b0 & 127) | ((b1 & 127) << 7) | (b2 << 14)
                  when 4 then (b0 & 127) | ((b1 & 127) << 7) | ((b2 & 127) << 14) | (b3 << 21)
                  else        (b0 & 127) | ((b1 & 127) << 7) | ((b2 & 127) << 14) | ((b3 & 127) << 21) | (b4 << 28) end
      end as u from y)
  select case when n is null then null when u >= 2147483648 then (u - 4294967296)::int else u::int end,
         case when n is null then null else off + n end
  from z
$$;

------------------------------------------------------------------------------------------------ VarLong
create or replace function proto.varlong(n bigint) returns bytea language plpgsql immutable parallel safe as $$
declare out bytea := '\x'; v bigint := n;
begin
  loop
    if (v & (-128)) = 0 then return out || set_byte('\x00'::bytea, 0, v::int); end if;
    out := out || set_byte('\x00'::bytea, 0, ((v & 127) | 128)::int);
    v := (v >> 7) & 144115188075855871;         -- logical shift: clear the 7 sign-extended top bits (mask 2^57-1)
  end loop;
end $$;

create or replace function proto.varlong_read(b bytea, off int default 0, out val bigint, out nxt int)
language plpgsql immutable parallel safe as $$
declare i int := 0; c int; r bigint := 0;
begin
  loop
    if off + i >= length(b) then val := null; nxt := null; return; end if;
    c := get_byte(b, off + i);
    if i = 9 and c > 1 then perform proto.bad('VarLong too long or tenth byte out of range'); end if;
    r := r | ((c & 127)::bigint << (7 * i));
    i := i + 1;
    if c < 128 then
      if i > 1 and c = 0 then perform proto.bad('overlong VarLong'); end if;
      val := r; nxt := off + i; return;
    end if;
  end loop;
end $$;

------------------------------------------------------------------------------------------------ fixed width, big-endian
create or replace function proto.i8(n int)   returns bytea language sql immutable parallel safe as $$ select set_byte('\x00'::bytea, 0, n & 255) $$;
create or replace function proto.i16(n int)  returns bytea language sql immutable parallel safe as $$ select set_byte(set_byte('\x0000'::bytea, 0, (n >> 8) & 255), 1, n & 255) $$;
create or replace function proto.i32(n int)  returns bytea language sql immutable parallel safe as $$ select int4send(n) $$;
create or replace function proto.i64(n bigint) returns bytea language sql immutable parallel safe as $$ select int8send(n) $$;
create or replace function proto.f32(x real) returns bytea language sql immutable parallel safe as $$ select float4send(x) $$;
create or replace function proto.f64(x float8) returns bytea language sql immutable parallel safe as $$ select float8send(x) $$;
create or replace function proto.bool(x boolean) returns bytea language sql immutable parallel safe as $$ select case when x then '\x01'::bytea else '\x00'::bytea end $$;

create or replace function proto.u8_read(b bytea, off int default 0)  returns int language sql immutable parallel safe as $$ select get_byte(b, off) $$;
create or replace function proto.i8_read(b bytea, off int default 0)  returns int language sql immutable parallel safe as $$ select get_byte(b, off) - (case when get_byte(b, off) >= 128 then 256 else 0 end) $$;
create or replace function proto.u16_read(b bytea, off int default 0) returns int language sql immutable parallel safe as $$ select (get_byte(b, off) << 8) | get_byte(b, off + 1) $$;
create or replace function proto.i16_read(b bytea, off int default 0) returns int language sql immutable parallel safe as $$
  select ((get_byte(b, off) << 8) | get_byte(b, off + 1)) - (case when get_byte(b, off) >= 128 then 65536 else 0 end) $$;
create or replace function proto.i32_read(b bytea, off int default 0) returns int language sql immutable parallel safe as $$
  select (((get_byte(b, off) & 127) << 24) | (get_byte(b, off + 1) << 16) | (get_byte(b, off + 2) << 8) | get_byte(b, off + 3))
         | (case when get_byte(b, off) >= 128 then (-2147483647 - 1) else 0 end) $$;
create or replace function proto.i64_read(b bytea, off int default 0) returns bigint language sql immutable parallel safe as $$
  select (((get_byte(b, off) & 127)::bigint << 56) | (get_byte(b, off + 1)::bigint << 48) | (get_byte(b, off + 2)::bigint << 40) | (get_byte(b, off + 3)::bigint << 32)
        | (get_byte(b, off + 4)::bigint << 24) | (get_byte(b, off + 5)::bigint << 16) | (get_byte(b, off + 6)::bigint << 8) | get_byte(b, off + 7)::bigint)
         | (case when get_byte(b, off) >= 128 then (-9223372036854775807::bigint - 1) else 0::bigint end) $$;
create or replace function proto.bool_read(b bytea, off int default 0) returns boolean language sql immutable parallel safe as $$ select get_byte(b, off) <> 0 $$;

-- IEEE 754 decode by arithmetic (Postgres has no bytea -> float cast). Exact: every step is a power-of-two scaling.
create or replace function proto.f64_read(b bytea, off int default 0) returns float8 language sql immutable parallel safe as $$
  select case
    when e = 2047 then case when m = 0 then (case when s = 1 then '-Infinity' else 'Infinity' end)::float8 else 'NaN'::float8 end
    when e = 0    then (case when s = 1 then -1.0 else 1.0 end)::float8 * (m::float8 / 4503599627370496.0) * power(2::float8, -1022)
    else               (case when s = 1 then -1.0 else 1.0 end)::float8 * (1.0::float8 + m::float8 / 4503599627370496.0) * power(2::float8, (e - 1023)::float8)
  end
  from (select (v >> 63) & 1 as s, (v >> 52) & 2047 as e, v & 4503599627370495 as m from (select proto.i64_read(b, off) as v) q) w
$$;
create or replace function proto.f32_read(b bytea, off int default 0) returns real language sql immutable parallel safe as $$
  select (case
    when e = 255 then case when m = 0 then (case when s = 1 then '-Infinity' else 'Infinity' end)::float8 else 'NaN'::float8 end
    when e = 0   then (case when s = 1 then -1.0 else 1.0 end)::float8 * (m::float8 / 8388608.0) * power(2::float8, -126)
    else              (case when s = 1 then -1.0 else 1.0 end)::float8 * (1.0::float8 + m::float8 / 8388608.0) * power(2::float8, (e - 127)::float8)
  end)::real
  from (select (v >> 31) & 1 as s, (v >> 23) & 255 as e, v & 8388607 as m from (select proto.i32_read(b, off)::bigint & 4294967295 as v) q) w
$$;

------------------------------------------------------------------------------------------------ strings, UUIDs, positions
create or replace function proto.string(s text) returns bytea language sql immutable parallel safe as $$
  select proto.varint(octet_length(s)) || convert_to(s, 'UTF8') $$;
create or replace function proto.string_read(b bytea, off int default 0, out val text, out nxt int)
language sql immutable parallel safe as $$
  select convert_from(substring(b from r.nxt + 1 for r.val), 'UTF8'), r.nxt + r.val from proto.varint_read(b, off) r $$;

create or replace function proto.uuid(u uuid) returns bytea language sql immutable parallel safe as $$ select decode(replace(u::text, '-', ''), 'hex') $$;
create or replace function proto.uuid_read(b bytea, off int default 0) returns uuid language sql immutable parallel safe as $$
  select encode(substring(b from off + 1 for 16), 'hex')::uuid $$;

-- Block position packed in one long: x 26 bits | z 26 bits | y 12 bits (all signed).
create or replace function proto.position(x int, y int, z int) returns bytea language sql immutable parallel safe as $$
  select int8send(((x::bigint & 67108863) << 38) | ((z::bigint & 67108863) << 12) | (y::bigint & 4095)) $$;
create or replace function proto.position_read(b bytea, off int default 0, out x int, out y int, out z int)
language sql immutable parallel safe as $$
  select (v >> 38)::int, ((v << 52) >> 52)::int, ((v << 26) >> 38)::int from (select proto.i64_read(b, off) as v) q $$;

------------------------------------------------------------------------------------------------ framing
-- [VarInt length][VarInt packet id][body].  Compression threshold -1 (off).
create or replace function proto.frame(packet_id int, body bytea) returns bytea language sql immutable parallel safe as $$
  select proto.varint(octet_length(proto.varint(packet_id)) + octet_length(body)) || proto.varint(packet_id) || body $$;
-- With compression enabled, a packet below the threshold is sent as [length][0][id][body]. (Larger packets need deflate; see docs/COMPRESSION.md.)
create or replace function proto.frame_small_compressed(packet_id int, body bytea) returns bytea language sql immutable parallel safe as $$
  select proto.varint(1 + octet_length(proto.varint(packet_id)) + octet_length(body)) || '\x00'::bytea || proto.varint(packet_id) || body $$;
