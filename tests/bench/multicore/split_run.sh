#!/usr/bin/env bash
# usage: tests/bench/multicore/split_run.sh MODE PLAYERS MOBS TICKS [PACE_MS] [CROWD]
#   MODE      off | inline | split          (dbcraft.entity-mode, sql/550)
#   PACE_MS   0 (default) = A runs ticks back to back;  50 = A is paced to a real 20 Hz server (sleeps out the rest of the interval)
#   CROWD     1 = the mobs stand within 12 blocks of random players (tests/bench/multicore/add_mobs.sql)
# env: DBCRAFT_PGPORT (54766), SPLIT_DB (ms_split: a database with the world generated, masks and floors built, sql/55x installed)
# Connection A runs the whole server tick with the synthetic walk of tests/bench/integration/bench.sql (gen -> timed_tick -> drain), as tests/bench/tick/run.sh does.
# In split mode connection B runs `call mc.entity_loop()` for the same time.  Prints A's tick summary, and for B: ticks run, ms per entity tick, lag behind A.
set -euo pipefail
cd "$(dirname "$0")/../../.."
MODE=$1; N=$2; MOBS=$3; TICKS=$4; PACE=${5:-0}; CROWD=${6:-0}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54766} PGUSER=postgres PGDATABASE=${SPLIT_DB:-ms_split} PGOPTIONS="-c client_min_messages=warning"
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql -f tests/bench/tick/cpu.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate tickbench.step" -c "update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode'" -c "truncate mc.entity_cmd, mc.entity_pickup_req, mc.entity_loop_log, mc.entity_tick_log" -c "select ibench.setup($N, ${SIDE:-100}, 10)" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "select count(*) from mc.refresh_visibility()" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -v mobs="$MOBS" -v area=790 -v crowd="$CROWD" -f tests/bench/multicore/add_mobs.sql > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "vacuum (full, analyze) mc.player, net.conn, mc.visible, mc.entity" > /dev/null
# the first entity tick announces every mob to every viewer who can see it (a join storm: 2,000 mobs x 500 crowded viewers = one tick of many seconds); the steady state is what is measured
psql -X -q -At -v ON_ERROR_STOP=1 -c "select set_config('dbcraft.entity_spawner', 'off', false)" -c "select mc.entity_tick((select game_time from mc.game_state))" -c "truncate mc.play_out" -c "vacuum (analyze) mc.entity, mc.entity_lane" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "update mc.server_property set value = '$MODE' where key = 'dbcraft.entity-mode'" > /dev/null
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
printf 'select setseed(0.99) is null;\n' > "$SCRIPT"
for i in $(seq 1 "$TICKS"); do
  if [ "$PACE" != 0 ]; then printf "select clock_timestamp() as tk0 \\\\gset\n"; fi
  printf 'select ibench.gen(1.0);\nselect tickbench.timed_tick();\nselect ibench.drain();\n'
  if [ "$PACE" != 0 ]; then printf "select pg_sleep(greatest(0, %s / 1000.0 - extract(epoch from clock_timestamp() - :'tk0'::timestamptz)));\n" "$PACE"; fi
done >> "$SCRIPT"
if [ "$MODE" = split ]; then
  PGAPPNAME=entity_b psql -X -q -At -c "call mc.entity_loop()" > /dev/null 2>&1 &
  sleep 1
fi
t0=$(date +%s.%N)
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$SCRIPT"
t1=$(date +%s.%N)
if [ "$MODE" = split ]; then
  psql -X -q -At -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'entity_b'" > /dev/null
fi
psql -X -q -At -c "select tickbench.summary('A mode=$MODE players=$N mobs=$MOBS crowd=$CROWD pace=$PACE load=$(cut -d' ' -f1 /proc/loadavg)')"
printf 'wall %.1f s for %s ticks = %.1f ms per tick\n' "$(echo "$t1 - $t0" | bc -l)" "$TICKS" "$(echo "($t1 - $t0) * 1000 / $TICKS" | bc -l)"
if [ "$MODE" != off ]; then
  psql -X -q -At -F ' ' -c "select 'entity ticks ' || count(*) || ' of ' || $TICKS || ' | ms avg ' || round(avg(ms)::numeric, 1) || ' p50 ' || round((percentile_cont(.5) within group (order by ms))::numeric, 1) || ' p99 ' || round((percentile_cont(.99) within group (order by ms))::numeric, 1) || ' max ' || round(max(ms)::numeric, 1) from mc.entity_loop_log where tick > (select min(tick) + 20 from mc.entity_loop_log)"
  psql -X -q -At -F ' ' -c "select 'entity lag (ticks behind A when B started the tick): ' || string_agg(lag || ':' || n, '  ' order by lag) from (select lag, count(*) as n from mc.entity_loop_log group by 1) q"
  psql -X -q -At -F ' ' -c "select 'entity tick log (inline mode / B): ms_total avg ' || round(avg(ms_total)::numeric, 1) || ' awake avg ' || round(avg(awake)) from mc.entity_tick_log"
fi
