-- Compact world storage (sql/950, docs/PERF-DISK.md): the profiles, the rewrite and the cache trim must not change one byte of what the world returns.
\! python3 tools/load_world_ref.py
insert into mc.dimension (name) values ('dbcraft:c950') on conflict do nothing;
delete from mc.flat_layer where dimension = 'dbcraft:c950';
insert into mc.flat_layer (dimension, y, block)
select 'dbcraft:c950', y, b from (values (-64, 'minecraft:bedrock'), (-63, 'minecraft:dirt'), (-62, 'minecraft:dirt'), (-61, 'minecraft:grass_block'),
                                        (-50, 'minecraft:stone'), (-20, 'minecraft:water'), (40, 'minecraft:glass')) l(y, b);
delete from mc.chunk where dimension = 'dbcraft:c950';
select mc.generate_flat('dbcraft:c950', cx, cz) from generate_series(0, 2) cx, generate_series(0, 1) cz;
-- varied content: many palette entries in one section, edits across sections, a block entity, a chunk with 200 distinct blocks (a bigger row)
select mc.set_block('dbcraft:c950', 1 + (g % 16), -61, 1 + (g / 16), (array['minecraft:gold_block', 'minecraft:oak_log[axis=y]', 'minecraft:diamond_block', 'minecraft:glowstone', 'minecraft:sand',
                                                                       'minecraft:gravel', 'minecraft:obsidian', 'minecraft:netherrack'])[1 + g % 8])
from generate_series(0, 100) g;
select mc.set_block('dbcraft:c950', 7, 100, 7, 'minecraft:emerald_block');
select mc.set_block('dbcraft:c950', 16 + (g % 16), -60 + (g / 16) % 8, 3 + (g / 128), (select name from ref.block b order by state_id limit 1 offset g))
from generate_series(0, 150) g;
select mc.chunk_packet('dbcraft:c950', cx, cz) is not null from generate_series(0, 2) cx, generate_series(0, 1) cz;     -- fills the cache and brings light up to date

select t.eq('the default profile is compact', (select value from mc.server_property where key = 'dbcraft.world-storage'), 'compact');
select t.eq('sections: fillfactor 90 and toast target 512', (select reloptions::text from pg_class where oid = 'mc.chunk_section'::regclass), '{fillfactor=90,toast_tuple_target=512}');
select t.eq('chunk, light, cache: fillfactors 90, 90, 100; the chunk row compresses every heightmap once it is over 2,032 bytes (target 128)',
            (select string_agg(relname || ':' || reloptions::text, ' ' order by relname) from pg_class where oid in ('mc.chunk'::regclass, 'mc.chunk_light'::regclass, 'mc.chunk_cache'::regclass)),
            'chunk:{fillfactor=90,toast_tuple_target=128} chunk_cache:{fillfactor=100} chunk_light:{fillfactor=90}');
select t.eq('the heightmaps of a chunk row are MAIN (compressed inside the row, never in the TOAST table)',
            (select string_agg(attname::text || attstorage::text, ',' order by attnum) from pg_attribute where attrelid = 'mc.chunk'::regclass and attname in ('hm_motion_blocking', 'hm_motion_blocking_no_leaves', 'hm_world_surface', 'light_ws')),
            'hm_motion_blockingm,hm_motion_blocking_no_leavesm,hm_world_surfacem,light_wsm');
select t.is_true('a never-edited flat chunk of the test world has compressed heightmaps (under 100 bytes each, 536 raw)',
                 (select pg_column_size(hm_world_surface) < 100 and pg_column_size(hm_motion_blocking_no_leaves) < 100 and pg_column_size(light_ws) < 100
                    from mc.chunk where dimension = 'dbcraft:c950' and cx = 2 and cz = 1));
select t.eq('every variable-length column of a section is MAIN (never moved to the TOAST table)',
            (select string_agg(attname::text || attstorage::text, ',' order by attnum) from pg_attribute where attrelid = 'mc.chunk_section'::regclass and attnum > 0 and attname in ('dimension', 'palette', 'data', 'biome_palette', 'biome_data')),
            'dimensionm,palettem,datam,biome_palettem,biome_datam');
select t.eq('light arrays are MAIN too', (select string_agg(attname::text || attstorage::text, ',' order by attnum) from pg_attribute where attrelid = 'mc.chunk_light'::regclass and attname in ('sky', 'block')), 'skym,blockm');
select t.eq('the write compression of sections and light is lz4 (3% of a set_block; pglz costs 11%)',
            (select string_agg(attrelid::regclass::text || '.' || attname::text || attcompression::text, ',' order by attrelid::regclass::text, attnum) from pg_attribute
              where attrelid in ('mc.chunk_section'::regclass, 'mc.chunk_light'::regclass) and attname in ('palette', 'data', 'sky')),
            'mc.chunk_light.skyl,mc.chunk_section.palettel,mc.chunk_section.datal');
select t.eq('the cache packet column keeps its pglz (the join path reads it): untouched by the profile',
            (select attstorage::text || attcompression::text from pg_attribute where attrelid = 'mc.chunk_cache'::regclass and attname = 'packet'), 'xp');

create temp table fp as select
  (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks_in('dbcraft:c950', 0, -64, 0, 47, 319, 31)) as blocks,
  (select md5(string_agg(encode(mc.chunk_packet_build('dbcraft:c950', cx, cz), 'hex'), '' order by cx, cz)) from generate_series(0, 2) cx, generate_series(0, 1) cz) as packets,
  (select md5(string_agg(encode(mc.light_wire('dbcraft:c950', cx, cz), 'hex'), '' order by cx, cz)) from generate_series(0, 2) cx, generate_series(0, 1) cz) as light,
  (select md5(string_agg(c.hm_motion_blocking::text || c.hm_motion_blocking_no_leaves::text || c.hm_world_surface::text || coalesce(c.light_ws::text, '') || coalesce(c.light_top::text, ''), ';' order by cx, cz)) from mc.chunk c where dimension = 'dbcraft:c950') as hm,
  (select md5(string_agg(palette::text || bits || encode(data, 'hex') || biome_palette::text || biome_bits || encode(biome_data, 'hex') || block_count || fluid_count, ';' order by cx, cz, sy)) from mc.chunk_section where dimension = 'dbcraft:c950') as sections,
  (select md5(string_agg(sky_kind || coalesce(encode(sky, 'hex'), '') || block_kind || coalesce(encode(block, 'hex'), ''), ';' order by cx, cz, idx)) from mc.chunk_light where dimension = 'dbcraft:c950') as light_rows,
  (select md5(string_agg(encode(packet, 'hex') || coalesce(encode(packet_z, 'hex'), ''), ';' order by cx, cz)) from mc.chunk_cache where dimension = 'dbcraft:c950') as cache_rows,
  (select md5(string_agg(cached_at::text, ';' order by cx, cz)) from mc.chunk_cache where dimension = 'dbcraft:c950') as cached_at,
  (select count(*) from mc.chunk_section where dimension = 'dbcraft:c950') as sections_n;
select t.is_true('the test world has several sections, and its stored sections are compressed on write (data of a section is lz4 or small)',
  (select sections_n from fp) >= 6 and (select count(*) from mc.chunk_section where dimension = 'dbcraft:c950' and pg_column_compression(data) = 'lz4') > 0);

-- the legacy profile and back: rows are rewritten raw, then compressed again, and nothing a reader can see moves
select t.eq('legacy profile reported', mc.set_world_storage('legacy'), 'legacy');
select t.eq('legacy: chunk rows as sql/200 creates them', (select reloptions::text from pg_class where oid = 'mc.chunk'::regclass), '{fillfactor=70}');
select t.eq('legacy: sections as sql/200 creates them', (select reloptions::text from pg_class where oid = 'mc.chunk_section'::regclass), '{fillfactor=70,toast_tuple_target=8160}');
select t.eq('legacy: light arrays EXTENDED again', (select string_agg(attname::text || attstorage::text, ',' order by attnum) from pg_attribute where attrelid = 'mc.chunk_light'::regclass and attname in ('sky', 'block')), 'skyx,blockx');
select t.raises('compact_world_storage refuses on the legacy profile', $$select mc.compact_world_storage()$$);
select t.raises('an unknown profile is refused', $$select mc.set_world_storage('tiny')$$);
select t.raises('an unknown compression is refused', $$select mc.set_world_storage('compact', 'zstd')$$);
select t.eq('the old switch of sql/291 selects the profiles', (select mc.set_section_compression(true) is null), true);
select t.eq('...compact again', (select value from mc.server_property where key = 'dbcraft.world-storage'), 'compact');

select t.is_true('compact_world_storage rewrites every row of the four tables and reports the count',
  mc.compact_world_storage() = (select (select count(*) from mc.chunk_section) + (select count(*) from mc.chunk_light) + (select count(*) from mc.chunk_cache) + (select count(*) from mc.chunk)));
select t.is_true('after the rewrite the sections are compressed with pglz (the smallest)',
  (select count(*) from mc.chunk_section where dimension = 'dbcraft:c950' and pg_column_compression(data) = 'pglz') > 0);
select t.eq('...and the profile is back: write compression lz4, setting unchanged', (select value from mc.server_property where key = 'dbcraft.world-storage-compression'), 'lz4');
select t.eq('...the columns too', (select string_agg(attname::text || attcompression::text, ',' order by attnum) from pg_attribute where attrelid = 'mc.chunk_section'::regclass and attname in ('palette', 'data')), 'palettel,datal');
select t.eq('the entity-mask trigger is enabled again after the rewrite', (select tgenabled::text from pg_trigger where tgname = 'entity_mask_invalidate' and tgrelid = 'mc.chunk_section'::regclass), 'O');
select t.eq('...and the cache trigger', (select tgenabled::text from pg_trigger where tgname = 'chunk_cache_touch' and tgrelid = 'mc.chunk_cache'::regclass), 'O');

select t.eq('same blocks', (select md5(string_agg(x || ',' || y || ',' || z || ',' || block, ';' order by x, y, z)) from mc.blocks_in('dbcraft:c950', 0, -64, 0, 47, 319, 31)), (select blocks from fp));
select t.eq('same chunk packets, byte for byte', (select md5(string_agg(encode(mc.chunk_packet_build('dbcraft:c950', cx, cz), 'hex'), '' order by cx, cz)) from generate_series(0, 2) cx, generate_series(0, 1) cz), (select packets from fp));
select t.eq('same light packet parts', (select md5(string_agg(encode(mc.light_wire('dbcraft:c950', cx, cz), 'hex'), '' order by cx, cz)) from generate_series(0, 2) cx, generate_series(0, 1) cz), (select light from fp));
select t.eq('same heightmaps and light cache keys', (select md5(string_agg(c.hm_motion_blocking::text || c.hm_motion_blocking_no_leaves::text || c.hm_world_surface::text || coalesce(c.light_ws::text, '') || coalesce(c.light_top::text, ''), ';' order by cx, cz)) from mc.chunk c where dimension = 'dbcraft:c950'), (select hm from fp));
select t.eq('same section rows, value for value', (select md5(string_agg(palette::text || bits || encode(data, 'hex') || biome_palette::text || biome_bits || encode(biome_data, 'hex') || block_count || fluid_count, ';' order by cx, cz, sy)) from mc.chunk_section where dimension = 'dbcraft:c950'), (select sections from fp));
select t.eq('same light rows, value for value', (select md5(string_agg(sky_kind || coalesce(encode(sky, 'hex'), '') || block_kind || coalesce(encode(block, 'hex'), ''), ';' order by cx, cz, idx)) from mc.chunk_light where dimension = 'dbcraft:c950'), (select light_rows from fp));
select t.eq('same cached packets and compressed frames, value for value', (select md5(string_agg(encode(packet, 'hex') || coalesce(encode(packet_z, 'hex'), ''), ';' order by cx, cz)) from mc.chunk_cache where dimension = 'dbcraft:c950'), (select cache_rows from fp));
select t.eq('the rewrite did not touch cached_at (the cache trigger is off for it)', (select md5(string_agg(cached_at::text, ';' order by cx, cz)) from mc.chunk_cache where dimension = 'dbcraft:c950'), (select cached_at from fp));

-- edits on rewritten rows
create temp table g_before as select mc.get_block('dbcraft:c950', 2, -61, 2) as b;
select mc.set_block('dbcraft:c950', 2, -61, 2, 'minecraft:lapis_block');
select t.eq('an edit on a rewritten section works', mc.get_block('dbcraft:c950', 2, -61, 2), 'minecraft:lapis_block');
select t.is_true('...the packet follows (the cache row is rebuilt: the version moved)', (select count(*) from mc.chunk c join mc.chunk_cache k using (dimension, cx, cz) where c.dimension = 'dbcraft:c950' and c.cx = 0 and c.cz = 0 and k.version = c.version) = 0
   and mc.chunk_packet('dbcraft:c950', 0, 0) is not null
   and (select count(*) from mc.chunk c join mc.chunk_cache k using (dimension, cx, cz) where c.dimension = 'dbcraft:c950' and c.cx = 0 and c.cz = 0 and k.version = c.version) = 1);
select mc.set_block('dbcraft:c950', 2, -61, 2, (select b from g_before));

-- trimming the cache: derived data, a missing row is rebuilt identically
select mc.chunk_packet('dbcraft:c950', cx, cz) is not null from generate_series(0, 2) cx, generate_series(0, 1) cz;
create temp table packets_now as select cx, cz, mc.chunk_packet('dbcraft:c950', cx, cz) as p from generate_series(0, 2) cx, generate_series(0, 1) cz;
alter table mc.chunk_cache disable trigger chunk_cache_touch;
update mc.chunk_cache set cached_at = now() - interval '2 hours' where dimension = 'dbcraft:c950' and cx = 0;
alter table mc.chunk_cache enable trigger chunk_cache_touch;
select t.eq('trim_chunk_cache deletes the rows older than the limit (the two chunks at cx = 0)', mc.trim_chunk_cache(interval '1 hour') >= 2, true);
select t.eq('...only those of the test world: the four others stay', (select count(*) from mc.chunk_cache where dimension = 'dbcraft:c950'), 4::bigint);
select t.eq('...and the next send rebuilds the same bytes', (select count(*) from packets_now n where mc.chunk_packet('dbcraft:c950', n.cx, n.cz) is distinct from n.p), 0::bigint);
select t.eq('...the cache has all six rows again', (select count(*) from mc.chunk_cache where dimension = 'dbcraft:c950'), 6::bigint);
alter table mc.chunk_cache disable trigger chunk_cache_touch;
update mc.chunk_cache set cached_at = now() - interval '3 hours' where dimension = 'dbcraft:c950' and cx = 1 and cz = 0;
alter table mc.chunk_cache enable trigger chunk_cache_touch;
update mc.chunk_cache set version = version where dimension = 'dbcraft:c950' and cx = 1 and cz = 0;
select t.is_true('writing a cache row sets cached_at to now (a hot chunk that is rebuilt is not trimmed)', (select cached_at > now() - interval '1 minute' from mc.chunk_cache where dimension = 'dbcraft:c950' and cx = 1 and cz = 0));

-- the profile survives a migration: sql/950 applies the profile named by the setting
select mc.set_world_storage('legacy');
\ir ../../sql/950_world_storage.sql
select t.eq('re-running sql/950 re-applies the profile of the setting (legacy stays legacy)', (select reloptions::text from pg_class where oid = 'mc.chunk_section'::regclass), '{fillfactor=70,toast_tuple_target=8160}');
select mc.set_world_storage('compact');
\ir ../../sql/950_world_storage.sql
select t.eq('...and compact stays compact', (select reloptions::text from pg_class where oid = 'mc.chunk_section'::regclass), '{fillfactor=90,toast_tuple_target=512}');

delete from mc.chunk where dimension = 'dbcraft:c950';
delete from mc.flat_layer where dimension = 'dbcraft:c950';
delete from mc.dimension where name = 'dbcraft:c950';
