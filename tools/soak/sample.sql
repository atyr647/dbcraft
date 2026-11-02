-- One sample of everything that could explain a slowdown over time; labelled lines, parsed by tools/soak/soak.py.   psql -At -F'|'
select 'tick', coalesce(max(tick), 0) from mc.server_tick_log;
select 'phases', count(*), round(avg(ms_total)::numeric, 2), round(avg(ms_process)::numeric, 2), round(avg(ms_game)::numeric, 2), round(avg(ms_blocks)::numeric, 2),
       round(avg(ms_chunks)::numeric, 2), round(avg(ms_drain)::numeric, 2), round(max(ms_total)::numeric, 1), round(avg(frames_in)::numeric, 0), round(avg(frames_out)::numeric, 0)
  from (select * from mc.server_tick_log order by tick desc limit 100) q;
select 'gwctl', ticks, round(coalesce(last_tick_ms, 0)::numeric, 1), round(coalesce(max_tick_ms, 0)::numeric, 0), late_ticks, connections from net.gateway_control;
select 'gwstats', ticks, late_ticks, round(tick_ms_avg::numeric, 1), round(tick_ms_max::numeric, 1), round(db_ms_avg::numeric, 1), frames_in, frames_out, connections, errors
  from net.gateway_stats order by ts desc limit 1;
select 'play', count(*) from net.conn where state = 'play';
select 'ka', count(*) filter (where keepalive_id is not null), coalesce(max((select max(tick) from mc.server_tick_log) - keepalive_sent_tick), 0)
  from mc.player where conn_id is not null;
select 'tbl', s.schemaname || '.' || s.relname, pg_total_relation_size(s.relid), s.n_live_tup, s.n_dead_tup, s.n_tup_hot_upd, s.n_tup_upd,
       coalesce(s.autovacuum_count, 0) + coalesce(s.vacuum_count, 0), coalesce(to_char(greatest(s.last_autovacuum, s.last_vacuum), 'HH24:MI:SS'), '-')
  from pg_stat_user_tables s where s.schemaname in ('mc', 'net') and (pg_total_relation_size(s.relid) > 2000000 or s.n_dead_tup > 2000)
 order by 3 desc limit 16;
select 'cat', s.relname, pg_total_relation_size(s.relid), s.n_live_tup, s.n_dead_tup
  from pg_stat_sys_tables s where s.relname in ('pg_class', 'pg_attribute', 'pg_statistic', 'pg_depend', 'pg_type', 'pg_index') order by 3 desc limit 6;
select 'act', count(*), coalesce(max(extract(epoch from now() - xact_start)), 0)::int, coalesce(max(age(backend_xmin)), 0)
  from pg_stat_activity where datname = 'dbcraft' and pid <> pg_backend_pid();
select 'xmin', pid, left(regexp_replace(query, '\s+', ' ', 'g'), 40), coalesce(extract(epoch from now() - xact_start), 0)::int, age(backend_xmin)
  from pg_stat_activity where backend_xmin is not null and datname = 'dbcraft' and pid <> pg_backend_pid() order by age(backend_xmin) desc limit 3;
select 'wait', coalesce(wait_event_type, '-'), coalesce(wait_event, '-'), count(*) from pg_stat_activity
 where datname = 'dbcraft' and state = 'active' and pid <> pg_backend_pid() group by 2, 3 order by 4 desc limit 4;
select 'locks_wait', count(*) from pg_locks where not granted;
select 'ckpt', checkpoints_timed, checkpoints_req from pg_stat_bgwriter;
select 'wal', pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint;
select 'gwpid', coalesce((select pid from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid() limit 1), 0);
select 'rel', (select count(*) from pg_class), (select count(*) from pg_class where relkind = 'r' and relpersistence = 't');
