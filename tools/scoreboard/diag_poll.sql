select 'conn_play', count(*) from net.conn where state = 'play';
select 'players_online', count(*) from mc.player where conn_id is not null;
select 'keepalive_pending', count(*) filter (where keepalive_id is not null), coalesce(max((select max(tick) from mc.server_tick_log) - keepalive_sent_tick), 0) from mc.player where conn_id is not null;
select 'player_bloat', n_live_tup, n_dead_tup, n_tup_hot_upd, n_tup_upd from pg_stat_user_tables where relid = 'mc.player'::regclass;
select 'queues', (select count(*) from net.inbox), (select count(*) from mc.play_in_work), (select count(*) from net.outbox), (select count(*) from mc.play_out);
select 'tick_log_rows', count(*), min(tick), max(tick) from mc.server_tick_log;
select 'last_ticks_ms', round(avg(ms_total)::numeric, 1), round(max(ms_total)::numeric, 0) from (select ms_total from mc.server_tick_log order by tick desc limit 100) q;
select 'errors', step, left(message, 100), count(*) from mc.error_log group by 1, 2, 3 order by 4 desc limit 3;
select 'gateway', ticks, round(last_tick_ms::numeric, 1), round(max_tick_ms::numeric, 0), late_ticks, connections from net.gateway_control;
