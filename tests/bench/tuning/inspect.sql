\pset pager off
\echo == tables: persistence, size, rows, storage options, indexes, toast  (mc, net, ibench excluded)
select c.relnamespace::regnamespace || '.' || c.relname as tbl,
       case c.relpersistence when 'u' then 'UNLOGGED' when 'p' then 'logged' else 'temp' end as persistence,
       pg_size_pretty(pg_table_size(c.oid)) as table_size, pg_size_pretty(pg_indexes_size(c.oid)) as idx_size,
       c.reltuples::bigint as est_rows, coalesce(array_to_string(c.reloptions, ','), '') as options,
       (select count(*) from pg_index i where i.indrelid = c.oid) as n_idx,
       (c.reltoastrelid <> 0) as has_toast
  from pg_class c
 where c.relkind = 'r' and c.relnamespace::regnamespace::text in ('mc', 'net')
 order by pg_total_relation_size(c.oid) desc;
\echo
\echo == per-tick transient tables (queues) and what indexes they carry
select i.indrelid::regclass as tbl, c.relname as index, pg_size_pretty(pg_relation_size(c.oid)) as size, pg_get_indexdef(i.indexrelid) as def
  from pg_index i join pg_class c on c.oid = i.indexrelid
 where i.indrelid::regclass::text in ('net.inbox', 'net.outbox', 'net.batch', 'net.play_inbox', 'mc.play_in', 'mc.play_in_work', 'mc.play_out', 'mc.visible', 'net.conn', 'mc.player', 'mc.block_event', 'mc.tick_log', 'mc.server_tick_log', 'mc.error_log', 'mc.chat_log', 'mc.chunk_cache')
 order by 1, 2;
\echo
\echo == columns of mc.player and which are indexed
select a.attname, format_type(a.atttypid, a.atttypmod) as type, a.attstorage as storage,
       exists (select 1 from pg_index i where i.indrelid = a.attrelid and a.attnum = any (i.indkey)) as indexed
  from pg_attribute a where a.attrelid = 'mc.player'::regclass and a.attnum > 0 and not a.attisdropped order by a.attnum;
\echo
\echo == TOAST: chunk cache and chunk tables
select c.relname, pg_size_pretty(pg_relation_size(c.oid)) as heap, pg_size_pretty(coalesce(pg_relation_size(c.reltoastrelid), 0)) as toast,
       (select string_agg(a.attname || ':' || a.attstorage::text, ' ') from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped and a.attstorage in ('e', 'x', 'm') and a.atttypid in ('bytea'::regtype, 'text'::regtype, 'jsonb'::regtype, 'text[]'::regtype)) as storage
  from pg_class c where c.relnamespace::regnamespace::text = 'mc' and c.relkind = 'r' and c.relname in ('chunk', 'chunk_section', 'chunk_light', 'chunk_cache', 'block_entity');
\echo
\echo == unlogged vs logged: logged tables that probably need not be
select relnamespace::regnamespace || '.' || relname as tbl, case relpersistence when 'u' then 'UNLOGGED' else 'logged' end as persistence from pg_class
 where relkind = 'r' and relnamespace::regnamespace::text in ('mc', 'net') order by relpersistence desc, 1;
\echo
\echo == functions marked stable/volatile that the tick calls in filters (mc.sid)
select p.oid::regprocedure, p.provolatile, p.prosrc from pg_proc p where p.proname in ('sid', 'cb', 'pkt') and p.pronamespace::regnamespace::text in ('mc', 'net');
