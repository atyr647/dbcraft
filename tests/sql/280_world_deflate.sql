-- Compression in SQL (sql/440).  Every claim about the compressed bytes is checked by a REAL inflater (tools/zlib_check.py: Python's zlib, which also verifies
-- the Adler-32 trailer); the Java Inflater check is tests/bench/world/inflate_java.sh.
--   checksums, the encoder on awkward inputs, wire frames, flat chunks (template splice), edited chunks (general encoder), real vanilla terrain packets.
\! python3 tools/load_world_ref.py

create temp table zin  (label text, kind text, stream text, expected text);
create temp table zout (label text, verdict text);

------------------------------------------------------------------------------------------------ checksums
select t.eq('adler32 of the empty string is 1', mc.adler32('\x'), 1::bigint);
select t.eq('adler32 of "Wikipedia" is 0x11E60398', mc.adler32('Wikipedia'::bytea), 300286872::bigint);
select t.eq('adler32 of "a"', mc.adler32('a'::bytea), 6422626::bigint);
select t.eq('adler32_combine: 20 random splits agree with the checksum of the whole', (
    select count(*)::int from (
      select d, s from (select decode(string_agg(md5((g * 7 + k)::text), ''), 'hex') d, (g * 37) % 300 as s from generate_series(1, 20) g, generate_series(1, 30) k group by g) q
    ) w where mc.adler32(d) <> mc.adler32_combine(mc.adler32(substring(d from 1 for s)), mc.adler32(substring(d from s + 1)), octet_length(d) - s)), 0);
select t.eq('adler32_combine with an empty second part', mc.adler32_combine(mc.adler32('abc'::bytea), 1, 0), mc.adler32('abc'::bytea));
select t.eq('adler32_combine with an empty first part', mc.adler32_combine(1, mc.adler32('abc'::bytea), 3), mc.adler32('abc'::bytea));

------------------------------------------------------------------------------------------------ the encoder, judged by zlib
insert into zin
select label, 'zlib', encode(mc.deflate_zlib(d), 'hex'), encode(d, 'hex') from (values
    ('empty', ''::bytea),
    ('one byte', '\x41'::bytea),
    ('three same', '\x414141'::bytea),
    ('four same', '\x41414141'::bytea),
    ('text', convert_to('hello hello hello world, aaaaaaaaaaaaaaaa bbbbbbbb', 'UTF8')),
    ('run 258', decode(repeat('00', 258), 'hex')),
    ('run 259 (258 + 1)', decode(repeat('00', 259), 'hex')),
    ('run 260', decode(repeat('00', 260), 'hex')),
    ('run 261', decode(repeat('00', 261), 'hex')),
    ('run 1000 of ff', decode(repeat('ff', 1000), 'hex')),
    ('run 5 then others', '\x0505050505010203'::bytea),
    ('alternating', decode(repeat('0102', 300), 'hex')),
    ('high bytes 144-255', (select string_agg(set_byte('\x00'::bytea, 0, b), ''::bytea order by b) from generate_series(144, 255) b)),
    ('all 256 values', (select string_agg(set_byte('\x00'::bytea, 0, b), ''::bytea order by b) from generate_series(0, 255) b)),
    ('all lengths 3..260 as runs', (select string_agg(decode(repeat(lpad(to_hex(l % 250), 2, '0'), l), 'hex'), ''::bytea order by l) from generate_series(1, 260) l)),
    ('random 3200 bytes', (select decode(string_agg(md5(g::text), ''), 'hex') from generate_series(1, 200) g)),
    ('sparse: zeros with a few values', (select string_agg(case when g % 97 = 0 then '\xff'::bytea else '\x00'::bytea end, ''::bytea order by g) from generate_series(1, 5000) g))
) v(label, d);

-- wire frames: [packet length][data length][zlib], the data length being the payload (packet id + body)
insert into zin
select 'frame ' || label, 'frame', encode(net.deflate_frame(pid, body), 'hex'), encode(proto.varint(pid) || body, 'hex')
from (values ('id 0x2e, 400 zero bytes', 46, decode(repeat('00', 400), 'hex')),
             ('id 0x80 (two byte VarInt), mixed', 128, decode(repeat('00ff', 200) || md5('x'), 'hex')),
             ('id 0, 70000 bytes (3-byte lengths)', 0, decode(repeat('ab', 70000), 'hex'))) v(label, pid, body);

------------------------------------------------------------------------------------------------ chunks
update mc.server_property set value = '256' where key = 'network-compression-threshold';
insert into mc.dimension (name) values ('dbcraft:z1') on conflict do nothing;
delete from mc.flat_layer where dimension = 'dbcraft:z1';
insert into mc.flat_layer (dimension, y, block) values ('dbcraft:z1', -64, 'minecraft:bedrock'), ('dbcraft:z1', -63, 'minecraft:dirt'), ('dbcraft:z1', -62, 'minecraft:dirt'),
       ('dbcraft:z1', -61, 'minecraft:grass_block'), ('dbcraft:z1', -50, 'minecraft:stone'), ('dbcraft:z1', -20, 'minecraft:water');
delete from mc.chunk where dimension = 'dbcraft:z1';
select t.eq('flat batch with compression on creates 12 chunks', mc.generate_flat_batch('dbcraft:z1', array(select x from generate_series(-3, 2) x, generate_series(0, 1) z order by x, z), array(select z from generate_series(-3, 2) x, generate_series(0, 1) z order by x, z)), 12);
select t.eq('every cached packet has its compressed frame', (select count(*)::int from mc.chunk_cache where dimension = 'dbcraft:z1' and packet_z is not null), 12);
select t.is_true('the spliced frames are small (an 8 KB flat packet compresses well)', (select max(octet_length(packet_z)) < 1500 and min(octet_length(packet)) > 5000 from mc.chunk_cache where dimension = 'dbcraft:z1'));
insert into zin
select 'flat chunk ' || cx || ',' || cz || ' (spliced)', 'frame', encode(packet_z, 'hex'), encode(substring(packet from (select nxt from proto.varint_read(packet, 0)) + 1), 'hex')
  from mc.chunk_cache where dimension = 'dbcraft:z1';
-- the same chunk through the general encoder gives a different stream (the splice stores the coordinates raw) but the same payload
insert into zin
select 'flat chunk ' || cx || ',' || cz || ' (general encoder)', 'frame', encode(mc.z_frame(substring(packet from (select nxt from proto.varint_read(packet, 0)) + 1)), 'hex'),
       encode(substring(packet from (select nxt from proto.varint_read(packet, 0)) + 1), 'hex')
  from mc.chunk_cache where dimension = 'dbcraft:z1' and cz = 0;
select t.eq('net.deflate_frame serves a chunk packet from the cache (same bytes as packet_z)',
    (select count(*)::int from mc.chunk_cache k where dimension = 'dbcraft:z1' and net.deflate_frame(mc.chunk_packet_id(), mc.packet_body(k.packet)) = k.packet_z), 12);
select t.is_true('...and a body that differs is compressed afresh, not served from the cache',
    (select net.deflate_frame(mc.chunk_packet_id(), set_byte(mc.packet_body(packet), 100, 77)) <> packet_z from mc.chunk_cache where dimension = 'dbcraft:z1' and cx = 0 and cz = 0));
insert into zin
select 'altered chunk body', 'frame', encode(net.deflate_frame(mc.chunk_packet_id(), set_byte(mc.packet_body(packet), 100, 77)), 'hex'),
       encode(proto.varint(mc.chunk_packet_id()) || set_byte(mc.packet_body(packet), 100, 77), 'hex')
  from mc.chunk_cache where dimension = 'dbcraft:z1' and cx = 0 and cz = 0;

-- an edited chunk: the cache is rebuilt with the general encoder and the compressed frame follows
select mc.set_block('dbcraft:z1', 3, -62, 3, 'minecraft:gold_block');
select t.is_true('after an edit the stale compressed frame is not used', (select (select count(*) from mc.chunk_cache k where k.dimension = 'dbcraft:z1' and k.cx = 0 and k.cz = 0 and k.version = c.version) = 0 from mc.chunk c where dimension = 'dbcraft:z1' and cx = 0 and cz = 0));
select md5(mc.chunk_packet('dbcraft:z1', 0, 0)) is not null;
select t.is_true('the rebuilt cache row has a fresh compressed frame', (select packet_z is not null and k.version = c.version from mc.chunk_cache k join mc.chunk c using (dimension, cx, cz) where k.dimension = 'dbcraft:z1' and k.cx = 0 and k.cz = 0));
insert into zin
select 'edited chunk (general encoder, cached)', 'frame', encode(packet_z, 'hex'), encode(substring(packet from (select nxt from proto.varint_read(packet, 0)) + 1), 'hex')
  from mc.chunk_cache where dimension = 'dbcraft:z1' and cx = 0 and cz = 0;
select t.eq('the edited chunk really changed (the gold block is there)', mc.get_block('dbcraft:z1', 3, -62, 3), 'minecraft:gold_block');

-- backfill: chunks cached before compression was on get their frames afterwards
update mc.chunk_cache set packet_z = null where dimension = 'dbcraft:z1' and cx < 0;
select t.is_true('backfill fills what is missing', mc.backfill_chunk_z(100) >= 6);
select t.eq('...and nothing is left without a compressed frame', (select count(*)::int from mc.chunk_cache where dimension = 'dbcraft:z1' and packet_z is null), 0);
insert into zin
select 'backfilled chunk ' || cx || ',' || cz, 'frame', encode(packet_z, 'hex'), encode(substring(packet from (select nxt from proto.varint_read(packet, 0)) + 1), 'hex')
  from mc.chunk_cache where dimension = 'dbcraft:z1' and cx < 0;

-- with compression off nothing is compressed at generation
update mc.server_property set value = '-1' where key = 'network-compression-threshold';
select mc.generate_flat('dbcraft:z1', 50, 50);
select t.is_true('compression off: no compressed frame is made at generation', (select packet_z is null from mc.chunk_cache where dimension = 'dbcraft:z1' and cx = 50 and cz = 50));

------------------------------------------------------------------------------------------------ real vanilla terrain
create temp table real_pk (cx int, cz int, framed text);
\copy real_pk from program 'python3 tools/import_chunk_capture.py expected'
select (select count(*) from real_pk) > 0 as have_real \gset
\if :have_real
  insert into zin
  select 'vanilla terrain ' || cx || ',' || cz, 'frame',
         encode(mc.z_frame(substring(decode(framed, 'hex') from (select nxt from proto.varint_read(decode(framed, 'hex'), 0)) + 1)), 'hex'),
         encode(substring(decode(framed, 'hex') from (select nxt from proto.varint_read(decode(framed, 'hex'), 0)) + 1), 'hex')
    from real_pk;
\else
  do $d$ begin raise notice 'SKIPPED real terrain compression: no terrain capture (tools/capture_vanilla.py against a normal-world server)'; end $d$;
\endif

------------------------------------------------------------------------------------------------ the judge
\copy (select * from zin order by label) to program 'python3 tools/zlib_check.py > /tmp/dbcraft_zcheck.tsv'
\copy zout from '/tmp/dbcraft_zcheck.tsv'
-- keep the inputs for the Java Inflater check (tests/bench/world/inflate_java.sh)
\copy (select * from zin order by label) to '/tmp/dbcraft_zin.tsv'
select t.eq('every input was judged', (select count(*)::int from zout), (select count(*)::int from zin));
select t.eq('a real inflater accepts every stream and gets the original bytes back (' || (select count(*) from zin) || ' streams)', (select count(*)::int from zout where verdict <> 'ok'), 0);
do $d$ declare bad text; begin
    select string_agg(label || ': ' || verdict, '; ') into bad from zout where verdict <> 'ok';
    if bad is not null then raise notice 'REJECTED: %', bad; end if;
end $d$;
\if :have_real
  do $d$ declare n int; raw bigint; z bigint; begin
      select count(*), sum(octet_length(decode(framed, 'hex'))) into n, raw from real_pk;
      select sum(octet_length(decode(stream, 'hex'))) into z from zin where label like 'vanilla terrain%';
      raise notice 'real vanilla terrain: % packets, % bytes raw -> % bytes compressed (%x)', n, raw, z, round(raw::numeric / z, 1);
  end $d$;
  select t.is_true('real terrain compresses by at least 2x with runs and fixed codes (measured 2.2x; zlib level 6 gets 5.3x on the same packets, see tests/bench/world/zlib_baseline.py)', (select sum(octet_length(decode(framed, 'hex')))::numeric from real_pk) / (select sum(octet_length(decode(stream, 'hex'))) from zin where label like 'vanilla terrain%') > 2);
\endif
update mc.server_property set value = '-1' where key = 'network-compression-threshold';
