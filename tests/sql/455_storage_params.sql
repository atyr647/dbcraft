-- sql/455_storage_params.sql: payload columns carry no statistics.
select t.eq('queue payload columns have statistics target 0',
    (select count(*) from pg_attribute a
      where a.attstattarget = 0
        and (a.attrelid::regclass::text, a.attname) in (values ('net.inbox', 'payload'), ('net.outbox', 'data'), ('net.batch', 'payload'), ('net.play_inbox', 'body'),
                                                                ('mc.play_in', 'body'), ('mc.play_in_work', 'body'), ('mc.play_out', 'data'), ('mc.chunk_cache', 'packet')))::int, 8);
select t.eq('other columns keep the default target', (select count(*) from pg_attribute a where a.attrelid = 'net.outbox'::regclass and a.attname = 'conn_id' and a.attstattarget = -1)::int, 1);
-- ANALYZE still works and collects statistics for the other columns, none for the payload
begin;
insert into net.outbox (conn_id, data) select 1, decode(md5(i::text), 'hex') from generate_series(1, 500) i;
analyze net.outbox;
select t.eq('statistics exist for conn_id', (select count(*) from pg_stats where schemaname = 'net' and tablename = 'outbox' and attname = 'conn_id')::int, 1);
select t.eq('no statistics for the payload', (select count(*) from pg_stats where schemaname = 'net' and tablename = 'outbox' and attname = 'data')::int, 0);
rollback;
