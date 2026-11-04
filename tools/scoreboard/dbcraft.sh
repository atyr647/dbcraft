#!/usr/bin/env bash
# Control the dbcraft server (own cluster, PL/Python dev gateway) for the scoreboard.  Own ports and log: nothing here touches the e2e scripts' defaults.
# usage: dbcraft.sh setup-db                       (once: tests/e2e/setup.sh with this cluster, see tools/scoreboard/README in docs/SCOREBOARD.md)
#        dbcraft.sh settings VIEW_DISTANCE         apply the vanilla-equivalent settings
#        dbcraft.sh tickmode default|batched       which tick the gateway calls (renames mc.server_tick, installs a wrapper)
#        dbcraft.sh start | stop | kill9 | status | psql [args...] | reset-world
set -euo pipefail
cd "$(dirname "$0")/../.."
# SCORE_PGDATA / SCORE_PGPORT / SCORE_GW_PORT / SCORE_OUT move the cluster, the gateway port and the log directory (several measurements on one machine);
# SCORE_GATEWAY=rust runs gateway/target/dbcraft-gateway (calling mc.server_tick() or, after `tickmode batched`, the wrapper) instead of the PL/Python net.run; its chunk generators are threads of the
# gateway (DBCRAFT_GW_GENERATORS, SCORE_GENERATORS, default 2) unless SCORE_PSQL_GENERATORS=1 starts `call mc.run_generator(64, 5)` loops in psql sessions as the older gateway needs.
export DBCRAFT_PGDATA=${SCORE_PGDATA:-/tmp/dbcraft-pg-score} DBCRAFT_PGPORT=${SCORE_PGPORT:-54599}
PORT=${SCORE_GW_PORT:-25643}
OUTD=${SCORE_OUT:-/tmp/scoreboard}
LOG=$OUTD/gateway.log
mkdir -p $OUTD
PSQL="psql -X -q -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft"
listening() {
  python3 - "$PORT" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); s.close()
except OSError:
    sys.exit(1)
PY
}
case "${1:-}" in
  setup-db) tests/e2e/setup.sh ;;
  settings)
    VD=${2:-10}
    $PSQL <<SQL
update mc.server_property set value = '$VD' where key = 'view-distance';
update mc.server_property set value = '10' where key = 'simulation-distance';
update mc.server_property set value = '1000' where key = 'max-players';
update mc.server_property set value = 'easy' where key = 'difficulty';
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
select 'settings applied: view distance $VD, chunk generation async (2 generator connections, like vanilla worker threads)';
SQL
    ;;
  tickmode)
    MODE=${2:-default}
    HAS=$($PSQL -c "select count(*) from pg_proc where proname = 'server_tick_default' and pronamespace = 'mc'::regnamespace")
    if [ "$MODE" = batched ] && [ "$HAS" = 0 ]; then
      $PSQL -c "alter function mc.server_tick() rename to server_tick_default" -c "create function mc.server_tick() returns bigint language sql as 'select mc.server_tick_batched()'"
    elif [ "$MODE" = default ] && [ "$HAS" != 0 ]; then
      $PSQL -c "drop function mc.server_tick()" -c "alter function mc.server_tick_default() rename to server_tick"
    fi
    echo "tick mode: $MODE"
    ;;
  start)
    # start the cluster (crash recovery included) and wait until it really accepts connections; retry the start once if it does not
    for attempt in 1 2 3; do
      tools/pg-dev.sh start > /dev/null 2>&1 || true
      for i in $(seq 1 100); do
        if psql -X -q -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft -c "select 1" > /dev/null 2>&1; then break 2; fi
        sleep 0.2
      done
    done
    $PSQL -c "update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0"
    if [ "${SCORE_GATEWAY:-plpython}" = rust ]; then
      DBCRAFT_GW_DATABASE_URL="host=/tmp port=$DBCRAFT_PGPORT user=postgres dbname=dbcraft" DBCRAFT_GW_LISTEN="0.0.0.0:$PORT" \
        DBCRAFT_GW_MAX_CONNECTIONS_PER_IP=0 DBCRAFT_GW_NEW_CONNECTIONS_PER_IP_PER_SEC=0 DBCRAFT_GW_LOGIN_ATTEMPTS_PER_IP_PER_MIN=0 DBCRAFT_GW_TICK_FN="${SCORE_TICKFN:-mc.server_tick()}" \
        DBCRAFT_GW_GENERATORS="$([ -n "${SCORE_PSQL_GENERATORS:-}" ] && echo 0 || echo "${SCORE_GENERATORS:-2}")" \
        nohup gateway/target/dbcraft-gateway > "$LOG" 2>&1 &
      echo $! > $OUTD/gateway.pid     # the Rust gateway is not a child of the postmaster: the runner adds its CPU to the cluster's (tools/scoreboard/run.py)
    else
      (nohup $PSQL -c "call net.run($PORT)" > "$LOG" 2>&1 &)
    fi
    for i in $(seq 1 100); do
      if listening; then break; fi
      sleep 0.2
    done
    $PSQL -c "update mc.generator_control set stop = false"
    if [ "${SCORE_GATEWAY:-plpython}" = rust ] && [ -z "${SCORE_PSQL_GENERATORS:-}" ]; then
      echo "dbcraft gateway listening on $PORT (+${SCORE_GENERATORS:-2} chunk generator threads of the gateway, parked while idle)"
    else
      for g in 1 2; do
        (nohup $PSQL -c "call mc.run_generator(64, 5)" > $OUTD/generator$g.log 2>&1 &)
      done
      echo "dbcraft gateway listening on $PORT (+2 chunk generator connections)"
    fi
    ;;
  stop)
    $PSQL -c "update mc.generator_control set stop = true" > /dev/null 2>&1 || true
    $PSQL -c "update net.gateway_control set stop = true" > /dev/null 2>&1 || true
    if [ "${SCORE_GATEWAY:-plpython}" = rust ]; then
      pkill -TERM -f "gateway/target/dbcraft-gateway" 2>/dev/null || true
      for i in $(seq 1 60); do pgrep -f "gateway/target/dbcraft-gateway" > /dev/null || break; sleep 0.25; done
    fi
    for i in $(seq 1 60); do
      N=$($PSQL -c "select count(*) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()" 2>/dev/null || echo 0)
      if [ "$N" = 0 ]; then break; fi
      sleep 0.25
    done
    # SCORE_TRIM_AT_STOP=1: give the world's disk space back when the run is over (a machine with little free disk; every run regenerates the world anyway)
    if [ -n "${SCORE_TRIM_AT_STOP:-}" ]; then $PSQL -c "truncate mc.chunk cascade" > /dev/null 2>&1 || true; fi
    echo "gateway stopped"
    ;;
  kill9)
    # an out-of-memory kill: SIGKILL to the postmaster and ALL its children at the same instant (killing the children first would let the postmaster
    # start its own crash restart, which a second kill then interrupts)
    PM=$(head -1 $DBCRAFT_PGDATA/postmaster.pid 2>/dev/null || true)
    if [ -n "$PM" ]; then
      PIDS="$PM $(pgrep -P "$PM" | tr '\n' ' ')"
      kill -9 $PIDS 2>/dev/null || true
      for i in $(seq 1 40); do
        if ! kill -0 "$PM" 2>/dev/null; then break; fi
        sleep 0.1
      done
    fi
    sleep 0.5
    echo "postgres killed"
    ;;
  status)
    $PSQL -c "select 'ticks='||ticks, 'last_tick_ms='||round(last_tick_ms::numeric,2), 'max_tick_ms='||round(max_tick_ms::numeric,2), 'late='||late_ticks, 'connections='||connections from net.gateway_control"
    ;;
  psql)
    shift
    exec psql -X -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft "$@"
    ;;
  reset-world)
    $PSQL -c "truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch" > /dev/null 2>&1 || true
    $PSQL -c "truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.chunk_request, mc.chunk_wanted" > /dev/null 2>&1 || true
    $PSQL -c "delete from mc.player" > /dev/null 2>&1 || true
    $PSQL -c "truncate mc.chunk cascade" > /dev/null 2>&1 || $PSQL -c "delete from mc.chunk where dimension = 'minecraft:overworld'" > /dev/null     # truncate: the world is regenerated for every run, and deleted rows would pile up (about 90 MB per run)
    echo "world reset (unexplored world, no players)"
    ;;
  *)
    echo "usage: $0 setup-db | settings VD | tickmode default|batched | start | stop | kill9 | status | psql | reset-world"
    exit 2
    ;;
esac
