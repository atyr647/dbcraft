#!/usr/bin/env bash
# Development helper for the player-visibility work (docs/PLAYER-VISIBILITY.md): a private cluster, the e2e database configured like the vanilla probe server
# (survival, flat, normal difficulty, view distance 3), and the PL/Python gateway on its own port.
#
#   tests/e2e/vis_dev.sh setup              (re)build the database (tests/e2e/setup.sh) and configure it
#   tests/e2e/vis_dev.sh start              start the gateway (call net.run) in the background
#   tests/e2e/vis_dev.sh stop               stop it
#   tests/e2e/vis_dev.sh cycle              stop, setup, start (after changing SQL files)
#   tests/e2e/vis_dev.sh psql [args]        psql into the database
#   tests/e2e/vis_dev.sh reload FILE...     apply SQL files to the running database (a gateway restart is needed for constant-folded ids only)
# environment: DBCRAFT_PGDATA (default /tmp/dbcraft-pg-vis), DBCRAFT_PGPORT (default 55841), VIS_GWPORT (default 25849), VIS_LOG (gateway log)
set -uo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-vis} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-55841}
GW=${VIS_GWPORT:-25849}; LOG=${VIS_LOG:-/tmp/dbcraft-vis-gateway.log}
PSQL="psql -X -q -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft"
case "${1:-}" in
  setup)
    tests/e2e/setup.sh > "${VIS_SETUP_LOG:-/tmp/dbcraft-vis-setup.log}" 2>&1 || { tail -20 "${VIS_SETUP_LOG:-/tmp/dbcraft-vis-setup.log}"; exit 1; }
    $PSQL -c "update mc.server_property set value = 'survival' where key = 'gamemode'" \
          -c "update mc.server_property set value = '3' where key in ('view-distance', 'simulation-distance')" \
          -c "update mc.server_property set value = 'normal' where key = 'difficulty'" \
          -c "select net.sync_settings()" > /dev/null
    echo "database ready" ;;
  start)
    $PSQL -c "update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0" > /dev/null
    (nohup $PSQL -c "call net.run($GW)" > "$LOG" 2>&1 &)
    for i in $(seq 1 50); do python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); s.connect(('127.0.0.1',$GW))" 2>/dev/null && break; sleep 0.2; done
    echo "gateway on $GW (log $LOG)" ;;
  stop)
    $PSQL -c "update net.gateway_control set stop = true" > /dev/null
    for i in $(seq 1 40); do [ "$($PSQL -c "select count(*) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()")" = 0 ] && break; sleep 0.25; done
    echo "gateway stopped" ;;
  cycle) "$0" stop; "$0" setup && "$0" start ;;
  psql) shift; exec psql -X -h /tmp -p "$DBCRAFT_PGPORT" -U postgres dbcraft "$@" ;;
  reload) shift; for f in "$@"; do psql -X -q -v ON_ERROR_STOP=1 -h /tmp -p "$DBCRAFT_PGPORT" -U postgres dbcraft -f "$f" || exit 1; done ;;
  *) echo "usage: $0 setup | start | stop | cycle | psql [args] | reload FILE..."; exit 2 ;;
esac
