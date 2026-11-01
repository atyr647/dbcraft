-- sql/450_tuning.sql: database-level defaults and log retention.
select t.is_true('database defaults are stored',
    (select array['jit=off', 'synchronous_commit=off', 'max_parallel_workers_per_gather=0', 'idle_in_transaction_session_timeout=60s'] <@ s.setconfig
       from pg_db_role_setting s where s.setdatabase = (select oid from pg_database where datname = current_database()) and s.setrole = 0));

-- retention: old diagnostics go, recent ones stay, chat is kept unless asked for
begin;
insert into mc.tick_log (tick, at, players) values (-1, now() - interval '30 days', 0), (-2, now() - interval '1 hour', 0);
insert into mc.server_tick_log (tick, at) values (-1, now() - interval '30 days'), (-2, now() - interval '1 hour');
insert into mc.error_log (at, tick, step, message) values (now() - interval '30 days', -1, 'x', 'old'), (now() - interval '1 hour', -2, 'x', 'recent');
insert into mc.chat_log (at, kind, sender_name, message) values (now() - interval '400 days', 'chat', 'x', 'old chat'), (now() - interval '1 hour', 'chat', 'x', 'recent chat');
create temp table pr on commit drop as select * from mc.prune_logs('7 days');
select t.eq('prune_logs deletes the old tick_log row', (select tick_log from pr), 1::bigint);
select t.eq('prune_logs deletes the old server_tick_log row', (select server_tick_log from pr), 1::bigint);
select t.eq('prune_logs deletes the old error_log row', (select error_log from pr), 1::bigint);
select t.eq('prune_logs leaves chat alone by default', (select chat_log from pr), 0::bigint);
select t.eq('recent tick_log row stays', (select count(*) from mc.tick_log where tick = -2)::int, 1);
select t.eq('recent error_log row stays', (select count(*) from mc.error_log where message = 'recent')::int, 1);
select t.eq('old chat stays when no chat retention is given', (select count(*) from mc.chat_log where message = 'old chat')::int, 1);
select t.eq('prune_logs deletes old chat when asked', (select chat_log from mc.prune_logs('7 days', '90 days')), 1::bigint);
select t.eq('recent chat stays', (select count(*) from mc.chat_log where message = 'recent chat')::int, 1);
rollback;
