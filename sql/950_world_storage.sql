-- Disk size of the world tables (docs/PERF-DISK.md).
--
-- The world tables were created for speed of the hot paths and stored everything raw: fillfactor 70 on every table, a toast_tuple_target of 8160 on mc.chunk_section so that
-- no section was ever compressed, text columns that PostgreSQL moves out of line first (STORAGE EXTENDED), and every flat chunk's cached packet carrying a 1,100-byte SQL-deflated
-- copy of a 99-byte stream.  Measured on 10,000 flat chunks that was 92.7 MiB against vanilla's 62.1 MiB of region files, and on real terrain 25 to 70 KB per chunk against
-- vanilla's 9 KB (sector-padded).  Where the bytes went and what each change cost the hot paths: docs/PERF-DISK.md.
--
-- This file puts the tables on the "compact" storage profile:
--
--   mc.chunk_section   every variable-length column STORAGE MAIN (compressed inline, never moved to the TOAST table: a byte loop over a detoasted value is quadratic,
--                      docs/COMPRESSION.md), compression lz4 (a write costs 3% of a set_block; pglz is 4 to 13% smaller but costs 11%: mc.compact_world_storage() rewrites cold rows
--                      with pglz), toast_tuple_target 512 (the largest value of a row is compressed first, the small columns are left alone once the row is small), fillfactor 90
--                      (an edit rewrites the row in place when the page has room).
--   mc.chunk_light     sky / block STORAGE MAIN (a 2,048-byte light array that does not compress used to be moved out of the row into the TOAST table), lz4, fillfactor 90
--   mc.chunk_cache     fillfactor 100 (a cached row is replaced as a whole, never edited in place); the packet column keeps pglz (reading it is on the join path)
--   mc.chunk           the heightmaps and the light cache key (four smallint[256], 2 KB of a 2.1 KB row) STORAGE MAIN with toast_tuple_target 128, fillfactor 90: the row of a flat
--                      chunk is 230 bytes instead of 1,722 (a row under 2,032 bytes is never compressed, so the template's compressed arrays are what the copies inherit)
--
-- Nothing a reader sees changes: same columns, same bytes, same functions (tests/sql/950 compares blocks, light and chunk packets before and after).  Rows written from now
-- on are stored compact; rows that exist keep the form they were written in until mc.compact_world_storage() rewrites them (then VACUUM FULL: tools/compact_world.sh does both).
--
--   select mc.set_world_storage('compact');            -- the default (what this file applies)
--   select mc.set_world_storage('compact', 'pglz');    -- compact with pglz for every write: smallest, a set_block costs about 10% more
--   select mc.set_world_storage('legacy');             -- the storage sql/200 creates: fillfactor 70, nothing compressed
--   select mc.compact_world_storage();                 -- rewrite the stored rows (pglz, the smallest) and keep the profile; heavy WAL; then VACUUM FULL mc.chunk, mc.chunk_section, mc.chunk_light, mc.chunk_cache
--   select mc.trim_chunk_cache(interval '1 hour');     -- drop cached chunk packets older than that (derived data: the next send of a chunk rebuilds it)
--
-- The profile is remembered in mc.server_property 'dbcraft.world-storage' ('compact' | 'legacy'), so a migration run later re-applies the profile you chose.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.world-storage', 'compact', 'compact', 'dbcraft: storage profile of the world tables, compact (compressed sections, fillfactor 90-100) or legacy (raw, fillfactor 70); see mc.set_world_storage and docs/PERF-DISK.md'),
    ('dbcraft.world-storage-compression', 'lz4', 'lz4', 'dbcraft: compression method of the compact profile for rows as they are written, lz4 (cheap writes) or pglz (smallest)')
on conflict (key) do nothing;

-- The profile.  p_compression NULL = the setting dbcraft.world-storage-compression.  lz4 on a server built without it falls back to pglz (with a notice).
create or replace function mc.set_world_storage(p_profile text, p_compression text default null) returns text language plpgsql volatile as $$
declare
    comp text := coalesce(p_compression, (select value from mc.server_property where key = 'dbcraft.world-storage-compression'), 'lz4');
begin
    if p_profile not in ('compact', 'legacy') then raise exception 'mc.set_world_storage: unknown profile "%" (use compact or legacy)', p_profile; end if;
    if comp not in ('pglz', 'lz4') then raise exception 'mc.set_world_storage: unknown compression "%" (use pglz or lz4)', comp; end if;
    if p_profile = 'compact' and comp = 'lz4' then
        begin
            execute 'alter table mc.chunk_light alter column sky set compression lz4';      -- fails on a server built without lz4
        exception when feature_not_supported then
            raise notice 'mc.set_world_storage: this server has no lz4; using pglz';
            comp := 'pglz';
        end;
    end if;
    if p_profile = 'compact' then
        -- every variable-length column of a section MAIN (compressed in the row, never moved to the TOAST table) and compressed with the chosen method
        execute 'alter table mc.chunk_section alter column dimension set storage main, alter column palette set storage main, alter column data set storage main, '
                'alter column biome_palette set storage main, alter column biome_data set storage main';
        execute format('alter table mc.chunk_section alter column palette set compression %1$s, alter column data set compression %1$s, '
                       'alter column biome_palette set compression %1$s, alter column biome_data set compression %1$s', comp);
        execute 'alter table mc.chunk_section set (fillfactor = 90, toast_tuple_target = 512)';
        execute 'alter table mc.chunk_light alter column sky set storage main, alter column block set storage main';
        execute format('alter table mc.chunk_light alter column sky set compression %1$s, alter column block set compression %1$s', comp);
        execute 'alter table mc.chunk_light set (fillfactor = 90)';
        execute 'alter table mc.chunk_cache set (fillfactor = 100)';
        -- the heightmaps (four smallint[256], 2 KB per row) are the whole of a chunk row: MAIN keeps them compressed inside the row, toast target 128 makes the row
        -- compress ALL of them as soon as it exceeds 2,032 bytes (PostgreSQL does not compress a smaller row at all, whatever the target is).  A flat chunk copies the
        -- compressed values of its template, so its row is 230 bytes instead of 1,722.
        execute 'alter table mc.chunk alter column dimension set storage main, alter column status set storage main, alter column hm_motion_blocking set storage main, '
                'alter column hm_motion_blocking_no_leaves set storage main, alter column hm_world_surface set storage main, alter column light_ws set storage main';
        execute format('alter table mc.chunk alter column hm_motion_blocking set compression %1$s, alter column hm_motion_blocking_no_leaves set compression %1$s, '
                       'alter column hm_world_surface set compression %1$s, alter column light_ws set compression %1$s', comp);
        execute 'alter table mc.chunk set (fillfactor = 90, toast_tuple_target = 128)';
    else
        -- what sql/200 creates
        execute 'alter table mc.chunk_section alter column dimension set storage extended, alter column palette set storage main, alter column data set storage main, '
                'alter column biome_palette set storage extended, alter column biome_data set storage main';
        execute 'alter table mc.chunk_section alter column palette set compression default, alter column data set compression default, '
                'alter column biome_palette set compression default, alter column biome_data set compression default';
        execute 'alter table mc.chunk_section set (fillfactor = 70, toast_tuple_target = 8160)';
        execute 'alter table mc.chunk_light alter column sky set storage extended, alter column block set storage extended';
        execute 'alter table mc.chunk_light alter column sky set compression default, alter column block set compression default';
        execute 'alter table mc.chunk_light set (fillfactor = 70)';
        execute 'alter table mc.chunk_cache set (fillfactor = 70)';
        execute 'alter table mc.chunk alter column dimension set storage extended, alter column status set storage extended, alter column hm_motion_blocking set storage extended, '
                'alter column hm_motion_blocking_no_leaves set storage extended, alter column hm_world_surface set storage extended, alter column light_ws set storage extended';
        execute 'alter table mc.chunk alter column hm_motion_blocking set compression default, alter column hm_motion_blocking_no_leaves set compression default, '
                'alter column hm_world_surface set compression default, alter column light_ws set compression default';
        execute 'alter table mc.chunk set (fillfactor = 70)';
        execute 'alter table mc.chunk reset (toast_tuple_target)';
    end if;
    update mc.server_property set value = p_profile where key = 'dbcraft.world-storage';
    if p_profile = 'compact' then update mc.server_property set value = comp where key = 'dbcraft.world-storage-compression'; end if;
    return p_profile || case when p_profile = 'compact' then '/' || comp else '' end;
end $$;

-- Cached chunk packets are derived data (a missing or stale row is rebuilt by the next send, 4 to 20 ms a chunk), so a cache that has grown can be cut back without losing anything.
-- cached_at is when the row was last written.  trim_chunk_cache returns the rows deleted.
alter table mc.chunk_cache add column if not exists cached_at timestamptz not null default now();
create or replace function mc.chunk_cache_touch() returns trigger language plpgsql as $$
begin new.cached_at := now(); return new; end $$;
drop trigger if exists chunk_cache_touch on mc.chunk_cache;
create trigger chunk_cache_touch before update on mc.chunk_cache for each row execute function mc.chunk_cache_touch();

create or replace function mc.trim_chunk_cache(p_older_than interval default interval '1 hour') returns bigint language plpgsql volatile as $$
declare n bigint;
begin
    delete from mc.chunk_cache where cached_at < now() - p_older_than;
    get diagnostics n = row_count;
    return n;
end $$;

-- Rewrite the stored rows of the four tables so that they are compressed with p_compression (pglz by default: the smallest), whatever form they were written in; the
-- profile and its write-time compression are restored afterwards.  Every compressible value is formed again (value || empty: PostgreSQL never recompresses a value that is
-- already compressed), so the content is byte for byte the same.  The triggers that react to an UPDATE (entity masks, cached_at) are switched off for the duration.
-- Dead row versions remain: follow with VACUUM FULL (tools/compact_world.sh does both).  Heavy WAL and an ACCESS EXCLUSIVE lock for the ALTER TABLEs: run it in a
-- maintenance window.  Returns the rows rewritten.
create or replace function mc.compact_world_storage(p_compression text default 'pglz') returns bigint language plpgsql volatile as $$
declare
    n   bigint := 0;
    k   bigint;
    cur text := (select value from mc.server_property where key = 'dbcraft.world-storage-compression');
begin
    if (select value from mc.server_property where key = 'dbcraft.world-storage') <> 'compact' then
        raise exception 'mc.compact_world_storage: the storage profile is legacy; select mc.set_world_storage(''compact'') first';
    end if;
    perform mc.set_world_storage('compact', p_compression);
    alter table mc.chunk_section disable trigger entity_mask_invalidate;
    alter table mc.chunk_cache disable trigger chunk_cache_touch;
    update mc.chunk_section set palette = array_cat(palette, '{}'::text[]), data = data || ''::bytea, biome_palette = array_cat(biome_palette, '{}'::text[]), biome_data = biome_data || ''::bytea;
    get diagnostics k = row_count;  n := n + k;
    update mc.chunk_light set sky = sky || ''::bytea, block = block || ''::bytea;
    get diagnostics k = row_count;  n := n + k;
    update mc.chunk_cache set packet = packet || ''::bytea, packet_z = packet_z || ''::bytea;
    get diagnostics k = row_count;  n := n + k;
    -- A chunk row under 2,032 bytes is never compressed, whatever the toast target says (a flat chunk's row is 1,722).  Padding the status by 2,100 characters pushes every row over
    -- the line, so the toaster compresses all the heightmaps; the second statement takes the padding off again (the padding itself compresses to a few bytes).
    update mc.chunk set status = status || repeat(' ', 2100),
                        hm_motion_blocking = case when hm_motion_blocking is null then null else array_cat(hm_motion_blocking, '{}'::smallint[]) end,
                        hm_motion_blocking_no_leaves = case when hm_motion_blocking_no_leaves is null then null else array_cat(hm_motion_blocking_no_leaves, '{}'::smallint[]) end,
                        hm_world_surface = case when hm_world_surface is null then null else array_cat(hm_world_surface, '{}'::smallint[]) end,
                        light_ws = case when light_ws is null then null else array_cat(light_ws, '{}'::smallint[]) end;
    update mc.chunk set status = left(status, length(status) - 2100);
    get diagnostics k = row_count;  n := n + k;
    alter table mc.chunk_cache enable trigger chunk_cache_touch;
    alter table mc.chunk_section enable trigger entity_mask_invalidate;
    perform mc.set_world_storage('compact', cur);
    return n;
end $$;

-- Apply the profile named by the setting (a migration re-applies what you chose; a fresh database gets 'compact').
select mc.set_world_storage(coalesce((select value from mc.server_property where key = 'dbcraft.world-storage'), 'compact'));

do $$
declare big bigint := (select count(*) from mc.chunk_section);
begin
    if big > 0 and (select value from mc.server_property where key = 'dbcraft.world-storage') = 'compact' then
        raise notice 'world storage profile applied; the % section rows that exist keep their old form until: select mc.compact_world_storage(); then VACUUM FULL (tools/compact_world.sh)', big;
    end if;
end $$;
