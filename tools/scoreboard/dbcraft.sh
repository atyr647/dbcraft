#!/usr/bin/env bash
# Control the dbcraft server (own cluster, PL/Python dev gateway) for the scoreboard.  Own ports and log: nothing here touches the e2e scripts' defaults.
# usage: dbcraft.sh setup-db                       (once: tests/e2e/setup.sh with this cluster, see tools/scoreboard/README in docs/SCOREBOARD.md)
#        dbcraft.sh settings VIEW_DISTANCE         apply the vanilla-equivalent settings
#        dbcraft.sh tickmode default|batched       which tick the gateway calls (renames mc.server_tick, installs a wrapper)
#        dbcraft.sh start | stop | kill9 | status | psql [args...] | reset-world
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=/tmp/dbcraft-pg-score DBCRAFT_PGPORT=54599
PORT=25643
LOG=/tmp/scoreboard/gateway.log
mkdir -p /tmp/scoreboard
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
    tools/pg-dev.sh start > /dev/null 2>&1 || true
    $PSQL -c "update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0"
    (nohup $PSQL -c "call net.run($PORT)" > "$LOG" 2>&1 &)
    for i in $(seq 1 100); do
      if listening; then break; fi
      sleep 0.2
    done
    $PSQL -c "update mc.generator_control set stop = false"
    for g in 1 2; do
      (nohup $PSQL -c "call mc.run_generator(64, 5)" > /tmp/scoreboard/generator$g.log 2>&1 &)
    done
    echo "dbcraft gateway listening on $PORT (+2 chunk generator connections)"
    ;;
  stop)
    $PSQL -c "update mc.generator_control set stop = true" > /dev/null 2>&1 || true
    $PSQL -c "update net.gateway_control set stop = true" > /dev/null 2>&1 || true
    for i in $(seq 1 60); do
      N=$($PSQL -c "select count(*) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()" 2>/dev/null || echo 0)
      if [ "$N" = 0 ]; then break; fi
      sleep 0.25
    done
    echo "gateway stopped"
    ;;
  kill9)
    PM=$(head -1 $DBCRAFT_PGDATA/postmaster.pid 2>/dev/null || true)
    if [ -n "$PM" ]; then
      pkill -9 -P "$PM" || true
      kill -9 "$PM" || true
    fi
    sleep 1
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
    $PSQL -c "delete from mc.chunk where dimension = 'minecraft:overworld'" > /dev/null
    echo "world reset (unexplored world, no players)"
    ;;
  *)
    echo "usage: $0 setup-db | settings VD | tickmode default|batched | start | stop | kill9 | status | psql | reset-world"
    exit 2
    ;;
esac
