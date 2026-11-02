-- sql/780: queue hygiene that does not depend on autovacuum (docs/SOAK.md).
-- A queue that was filled and emptied with DELETE keeps its size until a vacuum; net.trim_queue gives it back with a TRUNCATE, only when it is big AND empty.
truncate net.outbox, net.inbox;
delete from net.queue_trim_stat;
select t.eq('the setting exists with a default of 8 MiB', (select default_value from mc.server_property where key = 'dbcraft.queue-trim-bytes'), '8388608');
update mc.server_property set value = '1048576' where key = 'dbcraft.queue-trim-bytes';

-- a queue below the bound is left alone
insert into net.outbox (conn_id, data) select 1, decode(repeat(md5(g::text), 64), 'hex') from generate_series(1, 20) g;
delete from net.outbox;
select t.is_true('below the bound nothing is truncated', not net.trim_queue('net.outbox', 100000000));

-- bloat: 24 MB of rows inserted and deleted; the total size (heap + TOAST) stays
truncate net.outbox;
insert into net.outbox (conn_id, data) select 1, decode(repeat(md5(g::text), 512), 'hex') from generate_series(1, 3000) g;
delete from net.outbox;
select t.is_true('a drained queue keeps its bloat without a vacuum (the problem)', pg_total_relation_size('net.outbox') > 20000000);
select t.is_true('an empty queue above the bound is truncated', net.trim_queue('net.outbox', 1048576));
select t.is_true('...and its size is given back at once', pg_total_relation_size('net.outbox') < 100000);
select t.eq('the trim is counted', (select trims from net.queue_trim_stat where rel = 'net.outbox'::regclass), 1::bigint);
select t.is_true('...with the size it had', (select last_bytes > 20000000 from net.queue_trim_stat where rel = 'net.outbox'::regclass));

-- a row that is still waiting is never lost
insert into net.outbox (conn_id, data) select 1, decode(repeat(md5(g::text), 512), 'hex') from generate_series(1, 3000) g;
delete from net.outbox where seq % 2 = 0;
select t.is_true('a queue that still holds rows is not truncated', not net.trim_queue('net.outbox', 1048576));
select t.eq('...and the rows survive', (select count(*)::int from net.outbox), 1500);
truncate net.outbox;

-- the drain returns every byte AND trims afterwards
insert into net.conn (conn_id, compression) values (901, -1), (902, -1) on conflict (conn_id) do nothing;
insert into net.outbox (conn_id, data) select 901 + g % 2, decode(repeat(md5(g::text), 512), 'hex') from generate_series(1, 3000) g;
create temp table drained as select * from net.drain_outbox();
select t.eq('the drain returns both connections', (select count(*)::int from drained where conn_id in (901, 902)), 2);
select t.eq('...with every byte', (select sum(octet_length(data))::bigint from drained where conn_id in (901, 902)), 3000::bigint * 8192);
select t.is_true('...and the outbox is small again afterwards', pg_total_relation_size('net.outbox') < 100000);
select t.is_true('...trimmed by the drain itself (no vacuum involved)', (select trims >= 2 from net.queue_trim_stat where rel = 'net.outbox'::regclass));

-- the inbox is covered too, and 0 disables the whole thing
-- (the inbox column is compressed by TOAST, unlike the outbox: use data that does not compress)
insert into net.inbox (conn_id, payload) select 901, (select decode(string_agg(md5(random()::text || x::text), ''), 'hex') from generate_series(1, 512) x where g > 0) from generate_series(1, 3000) g;
select t.is_true('the inbox bloats too', pg_total_relation_size('net.inbox') > 20000000);
delete from net.inbox;
select t.is_true('a drained inbox is truncated by the trim', net.trim_queues() >= 1 and pg_total_relation_size('net.inbox') < 100000);
update mc.server_property set value = '0' where key = 'dbcraft.queue-trim-bytes';
insert into net.outbox (conn_id, data) select 1, decode(repeat(md5(g::text), 512), 'hex') from generate_series(1, 3000) g;
delete from net.outbox;
select t.eq('a bound of 0 disables the trimming', net.trim_queues(), 0);
select t.is_true('...so the bloat stays', pg_total_relation_size('net.outbox') > 20000000);
update mc.server_property set value = '8388608' where key = 'dbcraft.queue-trim-bytes';
truncate net.outbox, net.inbox;
delete from net.conn where conn_id in (901, 902);
