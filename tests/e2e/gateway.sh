#!/usr/bin/env bash
# Start / stop / inspect the development gateway (the PL/Python procedure net.run) on the e2e database.
# usage: tests/e2e/gateway.sh start [PORT] | stop | status | log        (default port 25621; log in /tmp/dbcraft-e2e/gateway.log)
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-int} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54399}
PSQL="psql -X -q -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft"
LOG=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e}/gateway.log
mkdir -p "${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e}"
case "${1:-}" in
  start)
    PORT=${2:-25621}
    $PSQL -c "update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0"
    (nohup $PSQL -c "call net.run($PORT)" > "$LOG" 2>&1 &)
    for i in $(seq 1 50); do
      python3 - "$PORT" <<'PY' && break
import socket, sys
s = socket.socket(); s.settimeout(0.3)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); s.close()
except OSError: sys.exit(1)
PY
      sleep 0.2
    done
    echo "gateway listening on $PORT (log $LOG)" ;;
  stop)
    $PSQL -c "update net.gateway_control set stop = true"
    for i in $(seq 1 40); do
      [ "$($PSQL -c "select count(*) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()")" = 0 ] && break
      sleep 0.25
    done
    echo "gateway stopped" ;;
  status) $PSQL -c "select 'ticks='||ticks, 'last_tick_ms='||round(last_tick_ms::numeric,2), 'max_tick_ms='||round(max_tick_ms::numeric,2), 'late='||late_ticks, 'connections='||connections from net.gateway_control" ;;
  log) cat "$LOG" ;;
  *) echo "usage: $0 start [PORT] | stop | status | log"; exit 2 ;;
esac
