-- VarInt: the published test vectors
select t.eq('varint '||n, encode(proto.varint(n), 'hex'), h)
from (values (0,'00'),(1,'01'),(2,'02'),(127,'7f'),(128,'8001'),(255,'ff01'),(25565,'ddc701'),(2097151,'ffff7f'),
             (2147483647,'ffffffff07'),(-1,'ffffffff0f'),(-2147483648,'8080808008')) v(n,h);
select t.eq('varint_read '||h, (proto.varint_read(decode(h,'hex'))).val, n)
from (values (0,'00'),(127,'7f'),(128,'8001'),(25565,'ddc701'),(2147483647,'ffffffff07'),(-1,'ffffffff0f'),(-2147483648,'8080808008')) v(n,h);
select t.eq('varint_read next offset', (proto.varint_read('\xff00ddc701'::bytea, 2)).nxt, 5);
select t.is_true('varint_read incomplete -> null', (select val is null and nxt is null from proto.varint_read('\x8080'::bytea)));
select t.is_true('varint_read empty -> null', (select val is null from proto.varint_read('\x'::bytea)));
select t.raises('varint overlong 2 bytes', $$select proto.varint_read('\x8000'::bytea)$$);
select t.raises('varint overlong 5 bytes', $$select proto.varint_read('\x8080808000'::bytea)$$);
select t.raises('varint fifth byte too big', $$select proto.varint_read('\xffffffff10'::bytea)$$);
select t.raises('varint six bytes', $$select proto.varint_read('\xffffffffffff'::bytea)$$);
select t.eq('varint roundtrip 20000 random ints', count(*)::int, 0) from (
  select n from (select (random()*4294967295 - 2147483648)::int n from generate_series(1,20000)) s
  where (proto.varint_read(proto.varint(n))).val is distinct from n) bad;
select t.eq('varint roundtrip around every 7-bit boundary', count(*)::int, 0) from (
  select n from (select generate_series(-3, 3) + (1 << k) d, 0 from generate_series(0, 30) k) x(n) where (proto.varint_read(proto.varint(n))).val is distinct from n) bad;

-- VarLong: published vectors
select t.eq('varlong '||n, encode(proto.varlong(n), 'hex'), h)
from (values (0::bigint,'00'),(2147483647,'ffffffff07'),(9223372036854775807,'ffffffffffffffff7f'),(-1,'ffffffffffffffffff01'),(-9223372036854775808,'80808080808080808001')) v(n,h);
select t.eq('varlong roundtrip 5000 random', count(*)::int, 0) from (
  select n from (select (random()*18446744073709551615 - 9223372036854775808)::bigint n from generate_series(1,5000)) s
  where (proto.varlong_read(proto.varlong(n))).val is distinct from n) bad;
select t.raises('varlong eleven bytes', $$select proto.varlong_read('\xffffffffffffffffffff01'::bytea)$$);

-- fixed width
select t.eq('i16 -2', encode(proto.i16(-2), 'hex'), 'fffe');
select t.eq('i16_read fffe', proto.i16_read('\xfffe'), -2);
select t.eq('u16_read fffe', proto.u16_read('\xfffe'), 65534);
select t.eq('i8_read ff', proto.i8_read('\xff'), -1);
select t.eq('i32_read 80000000', proto.i32_read('\x80000000'), -2147483648);
select t.eq('i32 roundtrip', count(*)::int, 0) from (select n from (select (random()*4294967295-2147483648)::int n from generate_series(1,5000)) s where proto.i32_read(proto.i32(n)) <> n) b;
select t.eq('i64_read min', proto.i64_read('\x8000000000000000'), -9223372036854775808);
select t.eq('i64 roundtrip', count(*)::int, 0) from (select n from (select (random()*18446744073709551615-9223372036854775808)::bigint n from generate_series(1,5000)) s where proto.i64_read(proto.i64(n)) <> n) b;

-- floats: exact round trip against Postgres's own encoders, including the awkward cases
select t.eq('f64 roundtrip '||x::text, proto.f64_read(proto.f64(x)), x)
from (values (0::float8),(1),(-1),(0.1),(1e308),(-1e-308),(4.9e-324),(2.2250738585072014e-308),(3.141592653589793),(64.0),(-0.5),('Infinity'::float8),('-Infinity'::float8)) v(x);
select t.is_true('f64 NaN', proto.f64_read(proto.f64('NaN'::float8)) = 'NaN'::float8);
select t.eq('f64 negative zero keeps sign bit', encode(proto.f64(proto.f64_read(proto.f64('-0'::float8))), 'hex'), '8000000000000000');
select t.eq('f64 roundtrip 20000 random magnitudes', count(*)::int, 0) from (
  select x from (select (random() - 0.5) * power(10::float8, (random() * 600 - 300)::int) x from generate_series(1,20000)) s where proto.f64_read(proto.f64(x)) <> x) b;
select t.eq('f32 roundtrip '||x::text, proto.f32_read(proto.f32(x)), x)
from (values (0::real),(1),(-1),(0.1),(1.5e38),(1e-45),(1.17549435e-38),(3.14159274),(70.5)) v(x);
select t.eq('f32 roundtrip 20000 random', count(*)::int, 0) from (
  select x from (select (((random() - 0.5) * power(10::float8, (random() * 70 - 35)::int)))::real x from generate_series(1,20000)) s where proto.f32_read(proto.f32(x)) <> x) b;

-- strings, UUIDs
select t.eq('string hello', encode(proto.string('hello'), 'hex'), '0568656c6c6f');
select t.eq('string utf8 length is bytes', encode(proto.string('é'), 'hex'), '02c3a9');
select t.eq('string_read', (proto.string_read('\x0568656c6c6f'::bytea)).val, 'hello');
select t.eq('string_read next', (proto.string_read('\xff0568656c6c6f'::bytea, 1)).nxt, 7);
select t.eq('string roundtrip unicode', (proto.string_read(proto.string('héllo wörld ✓ 日本語'))).val, 'héllo wörld ✓ 日本語');
select t.eq('uuid roundtrip', proto.uuid_read(proto.uuid('b50ad385-829d-3141-a216-7e7d7539ba7f')), 'b50ad385-829d-3141-a216-7e7d7539ba7f'::uuid);
select t.eq('uuid bytes', encode(proto.uuid('b50ad385-829d-3141-a216-7e7d7539ba7f'), 'hex'), 'b50ad385829d3141a2167e7d7539ba7f');

-- block position packing: hand-computed values (x<<38 | z<<12 | y)
select t.eq('position 1,0,0', encode(proto.position(1, 0, 0), 'hex'), '0000004000000000');
select t.eq('position 0,0,1', encode(proto.position(0, 0, 1), 'hex'), '0000000000001000');
select t.eq('position 0,1,0', encode(proto.position(0, 1, 0), 'hex'), '0000000000000001');
select t.eq('position -1,-1,-1 is all ones', encode(proto.position(-1, -1, -1), 'hex'), 'ffffffffffffffff');
select t.is_true('position_read -1', (select x = -1 and y = -1 and z = -1 from proto.position_read(proto.position(-1, -1, -1))));
select t.is_true('position wiki example', (select (x, y, z) = (18357644, 831, -20882616) from proto.position_read(proto.position(18357644, 831, -20882616))));
select t.eq('position roundtrip 20000 random', count(*)::int, 0) from (
  select * from (select (random()*67108863-33554432)::int x, (random()*4095-2048)::int y, (random()*67108863-33554432)::int z from generate_series(1,20000)) s
  where (select (r.x, r.y, r.z) from proto.position_read(proto.position(s.x, s.y, s.z)) r) is distinct from (s.x, s.y, s.z)) b;

-- framing
select t.eq('frame id 0 empty body', encode(proto.frame(0, '\x'), 'hex'), '0100');
select t.eq('frame with body', encode(proto.frame(2, '\xaabb'), 'hex'), '0302aabb');
select t.eq('frame small compressed', encode(proto.frame_small_compressed(2, '\xaabb'), 'hex'), '040002aabb');
select t.eq('frame id needing 2-byte varint', encode(proto.frame(200, '\x01'), 'hex'), '03c80101');
