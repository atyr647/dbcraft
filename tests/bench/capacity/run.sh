#!/usr/bin/env bash
# Moving-player capacity bench (docs/PERF-CAPACITY.md).
# usage: tests/bench/capacity/run.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS] [LABEL]
# env:   DBCRAFT_PGPORT (default 54411), DBCRAFT_BENCH_DB (default dbcraft; a database whose world is generated: capacity/world.sh), K (position packets per client and tick, default 1),
#        BOUND (blocks, default 780), VIEW (default 10), SKIP (warm-up ticks, default 30), PROF=1 (pg_stat_statements + function counters for the measured ticks, printed with TOPN rows)
# One line of results: wall and on-CPU time of the tick (tickbench: /proc/self/schedstat), the phases of mc.tick_log / mc.server_tick_log, output volume.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; TICKS=${4:-150}; LABEL=${5:-run}; K=${K:-1}; BOUND=${BOUND:-780}; SKIP=${SKIP:-30}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft} PGOPTIONS="-c client_min_messages=warning"
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql -f tests/bench/tick/cpu.sql -f tests/bench/capacity/bench.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate tickbench.step" -c "select capb.setup($N, $SIDE, ${VIEW:-10})" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "vacuum (full, analyze) mc.player, net.conn, mc.visible" > /dev/null 2>&1 || true
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
printf 'select setseed(0.99) is null;\n' > "$SCRIPT"
for i in $(seq 1 "$TICKS"); do
  printf 'select capb.gen(%s, %s, %s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$FRAC" "$K" "$BOUND"
  if [ "$i" = "$SKIP" ] && [ -n "${PROF:-}" ]; then
    cat >> "$SCRIPT" <<'SQL'
select pg_stat_statements_reset() is null;
select pg_stat_reset_single_function_counters(p.oid) is null from pg_proc p where p.pronamespace in ('mc'::regnamespace, 'net'::regnamespace, 'proto'::regnamespace);
select pg_stat_reset_shared('wal') is null;
set track_functions = 'all';
set pg_stat_statements.track = 'all';
SQL
  fi
done >> "$SCRIPT"
if [ -n "${PLANS:-}" ]; then       # PLANS=file: three more ticks with auto_explain (ANALYZE, BUFFERS, nested statements slower than PLANMIN ms); the plans come from the server log (DBCRAFT_PGDATA/log)
  printf "load 'auto_explain';\nset auto_explain.log_min_duration = %s;\nset auto_explain.log_analyze = on;\nset auto_explain.log_buffers = on;\nset auto_explain.log_timing = on;\nset auto_explain.log_nested_statements = on;\n" "${PLANMIN:-1}" >> "$SCRIPT"
  for i in 1 2 3; do printf 'select capb.gen(%s, %s, %s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$FRAC" "$K" "$BOUND"; done >> "$SCRIPT"
  LOGSTART=$(wc -c < "${DBCRAFT_PGDATA:-/tmp/dbcraft-pg}/log")
fi
# the gateway's maintenance thread (gateway/src/maint.rs: VACUUM (ANALYZE, SKIP_LOCKED) of the churned tables every maintenance_s = 5 seconds, a connection of its own): without it mc.player
# grows to 1,000 pages for 200 rows within a minute and every scan of it costs 1 ms more than in a running server.  MAINT=0 switches it off.
if [ "${MAINT:-1}" != 0 ]; then
  ( while :; do psql -X -q -At -c "vacuum (analyze, skip_locked) net.conn, mc.player, mc.visible, mc.chunk_wanted, mc.chunk_request, mc.kick, mc.block_event, mc.game_state, mc.server_tick_log, mc.tick_log" >/dev/null 2>&1; sleep 5; done ) &
  MAINT_PID=$!; trap 'kill $MAINT_PID 2>/dev/null; rm -f "$SCRIPT"' EXIT
fi
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$SCRIPT"
if [ -n "${PLANS:-}" ]; then tail -c +"$((LOGSTART + 1))" "${DBCRAFT_PGDATA:-/tmp/dbcraft-pg}/log" > "$PLANS"; fi
psql -X -q -At -c "select tickbench.summary('$LABEL players=$N moving=$FRAC k=$K load=$(cut -d' ' -f1 /proc/loadavg)', $SKIP)"
psql -X -q -At -F ' ' -c "select 'game phases (mc.tick_log avg ms): moves ' || round(avg(ms_moves)::numeric,2) || ' misc ' || round(avg(ms_misc)::numeric,2) || ' chat ' || round(avg(ms_chat)::numeric,2) || ' visibility ' || round(avg(ms_visibility)::numeric,2) || ' keepalive+dyn+vis+surv ' || round(avg(ms_keepalive)::numeric,2) || ' survival-slices ' || round(avg(ms_survival)::numeric,2) || ' movers ' || round(avg(movers)) from mc.tick_log where tick > $SKIP"
if [ -n "${PROF:-}" ]; then
  T=$((TICKS - SKIP))
  psql -X -q -At -F ' | ' -c "select 'wal bytes per tick: ' || round(wal_bytes / $T) || ', wal records per tick: ' || round(wal_records / $T) from pg_stat_wal"
  psql -X -q -At -F ' | ' -c "select round(total_exec_time::numeric / $T, 3) as exec_ms, round(total_plan_time::numeric / $T, 3) as plan_ms, round(calls::numeric / $T, 1) as calls, round((total_exec_time / nullif(calls,0))::numeric, 4) as ms_per_call, round(rows::numeric / $T) as rows, left(regexp_replace(query, '\s+', ' ', 'g'), 170) from pg_stat_statements where dbid = (select oid from pg_database where datname = current_database()) and query not like '%pg_stat_%' and query not like 'select ibench.%' and query not like 'select tickbench.%' and query not like 'select capb.%' order by (total_exec_time + total_plan_time) desc limit ${TOPN:-25}"
  echo "--- functions (self ms per tick, calls per tick)"
  psql -X -q -At -F ' | ' -c "select round(self_time::numeric / $T, 3), round(total_time::numeric / $T, 3), round(calls::numeric / $T, 2), schemaname || '.' || funcname from pg_stat_user_functions where schemaname in ('mc', 'net', 'proto') and calls > 0 order by self_time desc limit ${TOPF:-25}"
fi
