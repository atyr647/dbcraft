#!/usr/bin/env bash
# Profile a running scoreboard cell (docs/PERF-CAPACITY.md): wait until the players walk (the tick log shows many inbound frames per tick), reset the statement and function counters,
# let WINDOW seconds pass, print the most expensive statements and functions per tick, the WAL volume and the tick phases.  Needs pg_stat_statements preloaded and
# `alter system set pg_stat_statements.track = 'all'; alter system set track_functions = 'all'` for the cluster (the counters cost a few percent: use it for the profile, not for the numbers).
#   usage: tools/scoreboard/cenv_capacity tools/scoreboard/capprof_live.sh [WINDOW] [MIN_FRAMES]
set -u
WINDOW=${1:-30}; MINF=${2:-150}
P="psql -X -q -At -h /tmp -p $PGPORT -U postgres dbcraft"
for i in $(seq 1 1200); do
  n=$($P -c "select coalesce(round(min(f)), 0) from (select avg(frames_in) over (order by tick rows between 9 preceding and current row) as f from (select tick, frames_in from mc.server_tick_log order by tick desc limit 40) q) t where f is not null" 2>/dev/null || echo 0)
  [ "${n:-0}" -ge "$MINF" ] && break
  sleep 1
done
$P -c "select pg_stat_statements_reset() is null" -c "select pg_stat_reset_single_function_counters(p.oid) is null from pg_proc p where p.pronamespace in ('mc'::regnamespace, 'net'::regnamespace, 'proto'::regnamespace)" -c "select pg_stat_reset_shared('wal') is null" > /dev/null
T0=$($P -c "select max(tick) from mc.server_tick_log")
sleep "$WINDOW"
T1=$($P -c "select max(tick) from mc.server_tick_log")
T=$((T1 - T0))
echo "window: $WINDOW s, $T ticks (tick $T0 .. $T1)"
$P -F ' ' -c "select 'tick avg ms ' || round(avg(ms_total)::numeric,1) || ' process ' || round(avg(ms_process)::numeric,1) || ' game ' || round(avg(ms_game)::numeric,1) || ' blocks ' || round(avg(ms_blocks)::numeric,1) || ' chunks ' || round(avg(ms_chunks)::numeric,1) || ' drain ' || round(avg(ms_drain)::numeric,1) || ' frames_in ' || round(avg(frames_in)) || ' frames_out ' || round(avg(frames_out)) from mc.server_tick_log where tick > $T0 and tick <= $T1"
$P -F ' ' -c "select 'game phases: moves ' || round(avg(ms_moves)::numeric,1) || ' misc ' || round(avg(ms_misc)::numeric,1) || ' chat ' || round(avg(ms_chat)::numeric,1) || ' visibility ' || round(avg(ms_visibility)::numeric,1) || ' keepalive+dyn+vis+surv ' || round(avg(ms_keepalive)::numeric,1) || ' survival ' || round(avg(ms_survival)::numeric,1) from mc.tick_log where tick > $T0 and tick <= $T1"
$P -F ' | ' -c "select 'wal bytes per tick: ' || round(wal_bytes / $T) || ', records per tick: ' || round(wal_records / $T) || ', full page images ' || round(wal_fpi / $T, 1) from pg_stat_wal"
echo "--- statements: exec ms/tick | plan ms/tick | calls/tick | ms per call | rows/tick | text"
$P -F ' | ' -c "select round(total_exec_time::numeric / $T, 3), round(total_plan_time::numeric / $T, 3), round(calls::numeric / $T, 2), round((total_exec_time / nullif(calls,0))::numeric, 4), round(rows::numeric / $T, 1), left(regexp_replace(query, '\s+', ' ', 'g'), 150) from pg_stat_statements where dbid = (select oid from pg_database where datname = 'dbcraft') and query not like '%pg_stat_%' order by (total_exec_time + total_plan_time) desc limit ${TOPN:-40}"
echo "--- functions: self ms/tick | total ms/tick | calls/tick"
$P -F ' | ' -c "select round(self_time::numeric / $T, 3), round(total_time::numeric / $T, 3), round(calls::numeric / $T, 2), schemaname || '.' || funcname from pg_stat_user_functions where calls > 0 order by self_time desc limit ${TOPF:-40}"
