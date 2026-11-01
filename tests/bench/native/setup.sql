-- Benchmark data for the native deflate evaluation (tests/bench/native/bench.py).  Run in a migrated database that has the dbcraft_zlib extension (sql/441 loads it).
--   real_pk(id, payload)       the REAL vanilla terrain chunk packets of the capture (packet id + body), the data the SQL compressor was measured on
--   real_slices(pk, i, slice)  the same payloads cut into 4 KiB pieces (a stand-in for "one section" of compressible data)
--   flat_pk(id, payload)       flat-world chunk packets (what the template splice handles in microseconds)
\set ON_ERROR_STOP on
set jit = off;
\! python3 tools/load_world_ref.py
create schema if not exists bench;
drop table if exists bench.real_slices, bench.real_pk, bench.flat_pk;
create table bench.real_pk (id serial primary key, payload bytea not null);
alter table bench.real_pk alter column payload set storage external;
create temp table raw_pk (cx int, cz int, framed text);
\copy raw_pk from program 'python3 tools/import_chunk_capture.py expected'
insert into bench.real_pk (payload)
select substring(decode(framed, 'hex') from (select nxt from proto.varint_read(decode(framed, 'hex'), 0)) + 1) from raw_pk order by cx, cz;
select count(*) as n_real from bench.real_pk \gset
\echo real terrain packets loaded: :n_real
create table bench.real_slices as
select p.id as pk, i, substring(p.payload from 1 + i * 4096 for 4096) as slice
  from bench.real_pk p, lateral generate_series(0, (octet_length(p.payload) - 1) / 4096) i;
alter table bench.real_slices alter column slice set storage external;
create table bench.flat_pk (id serial primary key, payload bytea not null);
update mc.server_property set value = '-1' where key = 'network-compression-threshold';
insert into mc.dimension (name) values ('dbcraft:nbench') on conflict do nothing;
delete from mc.flat_layer where dimension = 'dbcraft:nbench';
insert into mc.flat_layer (dimension, y, block) values ('dbcraft:nbench', -64, 'minecraft:bedrock'), ('dbcraft:nbench', -63, 'minecraft:dirt'), ('dbcraft:nbench', -62, 'minecraft:dirt'),
       ('dbcraft:nbench', -61, 'minecraft:grass_block'), ('dbcraft:nbench', -50, 'minecraft:stone'), ('dbcraft:nbench', -20, 'minecraft:water');
delete from mc.chunk where dimension = 'dbcraft:nbench';
select mc.generate_flat_batch('dbcraft:nbench', array(select x from generate_series(1, 40) x), array(select 0 from generate_series(1, 40) x)) as made \gset
insert into bench.flat_pk (payload)
select substring(packet from (select nxt from proto.varint_read(packet, 0)) + 1) from mc.chunk_cache where dimension = 'dbcraft:nbench' order by cx;
analyze bench.real_pk; analyze bench.real_slices; analyze bench.flat_pk;
select 'real packets' as set, count(*) n, sum(octet_length(payload)) bytes, round(avg(octet_length(payload))) avg_bytes from bench.real_pk
union all select 'real 4KiB slices', count(*), sum(octet_length(slice)), round(avg(octet_length(slice))) from bench.real_slices
union all select 'flat packets', count(*), sum(octet_length(payload)), round(avg(octet_length(payload))) from bench.flat_pk;
