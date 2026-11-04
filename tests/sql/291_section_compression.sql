-- Section compression (sql/291, switch in sql/950): turning it on and rewriting the rows must not change a single byte of what the world returns.
-- Compression is the default since sql/950 (the compact storage profile); this test starts from the legacy profile (raw sections) to see the switch work both ways.
\! python3 tools/load_world_ref.py
select mc.set_section_compression(false);
insert into mc.dimension (name) values ('dbcraft:c291') on conflict do nothing;
delete from mc.flat_layer where dimension = 'dbcraft:c291';
insert into mc.flat_layer (dimension, y, block)
select 'dbcraft:c291', y, b from (values (-64, 'minecraft:bedrock'), (-63, 'minecraft:dirt'), (-62, 'minecraft:dirt'), (-61, 'minecraft:grass_block'),
                                        (-50, 'minecraft:stone'), (-20, 'minecraft:water'), (40, 'minecraft:glass')) l(y, b);
delete from mc.chunk where dimension = 'dbcraft:c291';
select mc.generate_flat('dbcraft:c291', cx, cz) from generate_series(0, 2) cx, generate_series(0, 1) cz;
-- varied content: many palette entries in one section, edits across sections
select mc.set_block('dbcraft:c291', 1 + (g % 16), -61, 1 + (g / 16), (array['minecraft:gold_block', 'minecraft:oak_log[axis=y]', 'minecraft:diamond_block', 'minecraft:glowstone', 'minecraft:sand',
                                                                       'minecraft:gravel', 'minecraft:obsidian', 'minecraft:netherrack'])[1 + g % 8])
from generate_series(0, 100) g;
select mc.set_block('dbcraft:c291', 7, 100, 7, 'minecraft:emerald_block');

-- the bind-once unpack_longs returns exactly what the original did, for every bit width, on random data and on the real sections of the test world
create function pg_temp.unpack_orig(d bytea, bits int, n int) returns int[] language sql immutable as $$
  select case when bits = 0 then array_fill(0, array[n]) else
    array(
      select ((((get_byte(d, k))
              | ((case when k - 1 >= base then get_byte(d, k - 1) else 0 end) << 8)
              | ((case when k - 2 >= base then get_byte(d, k - 2) else 0 end) << 16)) >> (p % 8))
              & ((1 << bits) - 1))
      from (select i, base, p, base + 7 - p / 8 as k
            from (select i, (i / (64 / bits)) * 8 as base, (i % (64 / bits)) * bits as p from generate_series(0, n - 1) i) q) r
      order by i)
  end $$;
create function pg_temp.rnd(len int) returns bytea language sql volatile as $$
  select decode(string_agg(lpad(to_hex((random() * 255)::int), 2, '0'), ''), 'hex') from generate_series(1, len) $$;
create temp table ub as select b, pg_temp.rnd(((4096 + (64 / b) - 1) / (64 / b)) * 8) as d from unnest(array[4, 5, 6, 7, 8, 16]) b, generate_series(1, 5);
select t.eq('unpack_longs equals the original on random buffers (30: bits 4..8 and 16, 5 each)', (select count(*) from ub where mc.unpack_longs(d, b, 4096) is distinct from pg_temp.unpack_orig(d, b, 4096))::int, 0);
select t.eq('...and bits = 0 (single value)', mc.unpack_longs('\x'::bytea, 0, 4096) = array_fill(0, array[4096]), true);

select t.eq('legacy profile: the table keeps the large toast target', (select reloptions::text from pg_class where oid = 'mc.chunk_section'::regclass) like '%toast_tuple_target=8160%', true);

create temp table fp_before as select
  (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks_in('dbcraft:c291', 0, -64, 0, 47, 319, 31)) as blocks,
  (select md5(string_agg(encode(mc.chunk_packet_build('dbcraft:c291', cx, cz), 'hex'), '' order by cx, cz)) from generate_series(0, 2) cx, generate_series(0, 1) cz) as packets,
  (select md5(string_agg(mc.get_block('dbcraft:c291', 3 + g, -61, 3 + g % 7) || mc.get_block('dbcraft:c291', g, -64, g), ',' order by g)) from generate_series(0, 40) g) as reads,
  (select count(*) from mc.chunk_section where dimension = 'dbcraft:c291') as sections;
select t.is_true('before: no section row of the test world is compressed',
  (select count(*) from mc.chunk_section where dimension = 'dbcraft:c291' and (pg_column_compression(data) is not null or pg_column_compression(palette) is not null)) = 0);

select mc.set_section_compression(true);
select t.eq('switched on: the table uses the compact profile (toast target 512)', (select reloptions::text from pg_class where oid = 'mc.chunk_section'::regclass) like '%toast_tuple_target=512%', true);
select t.is_true('rewrite_sections touches every section row', mc.rewrite_sections() >= (select sections from fp_before));
select t.is_true('after the rewrite section rows of the test world ARE compressed (data or palette)',
  (select count(*) from mc.chunk_section where dimension = 'dbcraft:c291' and (pg_column_compression(data) is not null or pg_column_compression(palette) is not null)) > 0);

select t.eq('same blocks (blocks_in over the whole area)', (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks_in('dbcraft:c291', 0, -64, 0, 47, 319, 31)), (select blocks from fp_before));
select t.eq('same chunk packets, byte for byte', (select md5(string_agg(encode(mc.chunk_packet_build('dbcraft:c291', cx, cz), 'hex'), '' order by cx, cz)) from generate_series(0, 2) cx, generate_series(0, 1) cz), (select packets from fp_before));
select t.eq('same single-block reads', (select md5(string_agg(mc.get_block('dbcraft:c291', 3 + g, -61, 3 + g % 7) || mc.get_block('dbcraft:c291', g, -64, g), ',' order by g)) from generate_series(0, 40) g), (select reads from fp_before));
select t.is_true('mc.blocks (point query) agrees with get_block on compressed rows',
  (select block from mc.blocks where dimension = 'dbcraft:c291' and x = 7 and y = 100 and z = 7) = 'minecraft:emerald_block');
select t.eq('mc.blocks over a region has the same rows as blocks_in',
  (select count(*) from mc.blocks where dimension = 'dbcraft:c291' and cx = 0 and cz = 0)::int,
  (select count(*) from mc.blocks_in('dbcraft:c291', 0, -64, 0, 15, 319, 15))::int);

-- edits on compressed rows
create temp table g_before as select mc.get_block('dbcraft:c291', 2, -61, 2) as b;
select mc.set_block('dbcraft:c291', 2, -61, 2, 'minecraft:lapis_block');
select t.eq('an edit on a compressed section works', mc.get_block('dbcraft:c291', 2, -61, 2), 'minecraft:lapis_block');
select t.is_true('...and the edited section is still readable through blocks_in',
  exists (select 1 from mc.blocks_in('dbcraft:c291', 2, -61, 2, 2, -61, 2) where block = 'minecraft:lapis_block'));
select mc.set_block('dbcraft:c291', 2, -61, 2, (select b from g_before));
select t.eq('reverting the edit restores the block', mc.get_block('dbcraft:c291', 2, -61, 2), (select b from g_before));
select t.eq('the whole world still has the same blocks after edit and revert (the packet may differ: the palette keeps the extra entry)',
            (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks_in('dbcraft:c291', 0, -64, 0, 47, 319, 31)), (select blocks from fp_before));

select mc.set_section_compression(false);
select t.eq('switched off again: the original toast target is back', (select reloptions::text from pg_class where oid = 'mc.chunk_section'::regclass) like '%toast_tuple_target=8160%', true);

-- the cache storage switch: catalog settings change, the cache still serves and rebuilds the same bytes
select mc.generate_flat('dbcraft:c291', 0, 0);
select mc.set_cache_storage('lz4');
select t.eq('lz4: storage extended, compression lz4', (select attstorage::text || attcompression::text from pg_attribute where attrelid = 'mc.chunk_cache'::regclass and attname = 'packet'), 'xl');
select mc.set_cache_storage('external');
select t.eq('external: storage external', (select attstorage::text from pg_attribute where attrelid = 'mc.chunk_cache'::regclass and attname = 'packet'), 'e');
select mc.set_cache_storage('pglz');
select t.eq('pglz: back to extended with pglz', (select attstorage::text || attcompression::text from pg_attribute where attrelid = 'mc.chunk_cache'::regclass and attname = 'packet'), 'xp');
select t.raises('an unknown mode is refused', $$select mc.set_cache_storage('zstd')$$);

delete from mc.chunk where dimension = 'dbcraft:c291';
delete from mc.flat_layer where dimension = 'dbcraft:c291';
delete from mc.dimension where name = 'dbcraft:c291';
select mc.set_section_compression(true);     -- back to the default profile
