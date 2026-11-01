#!/usr/bin/env bash
# Build and run a dbcraft server for the real-client checks, on ports of its own (so it cannot collide with tests/e2e).
# usage: tools/realclient/dbcraft_server.sh setup | start | stop | status | log | psql [args]
# env: DBCRAFT_PGDATA (/tmp/dbcraft-pg-client), DBCRAFT_PGPORT (54477), GW_PORT (25633), GW_LOG (/tmp/mc-client/gateway.log)
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-client} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54477}
GW_PORT=${GW_PORT:-25633}; GW_LOG=${GW_LOG:-/tmp/mc-client/gateway.log}
PSQL="psql -X -q -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft"
case "${1:-}" in
  setup) tests/e2e/setup.sh ;;
  start)
    $PSQL -c "update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0"
    mkdir -p "$(dirname "$GW_LOG")"
    (nohup $PSQL -c "call net.run($GW_PORT)" > "$GW_LOG" 2>&1 < /dev/null &)
    for i in $(seq 1 50); do
      python3 -I - "$GW_PORT" <<'PY' && break
import socket, sys
s = socket.socket(); s.settimeout(0.3)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); s.close()
except OSError: sys.exit(1)
PY
      sleep 0.2
    done
    echo "dbcraft gateway listening on $GW_PORT (log $GW_LOG)" ;;
  stop)
    $PSQL -c "update net.gateway_control set stop = true"
    for i in $(seq 1 40); do
      [ "$($PSQL -c "select count(*) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()")" = 0 ] && break
      sleep 0.25
    done
    echo "gateway stopped" ;;
  status) $PSQL -c "select 'ticks='||ticks, 'last_tick_ms='||round(last_tick_ms::numeric,2), 'max_tick_ms='||round(max_tick_ms::numeric,2), 'late='||late_ticks, 'connections='||connections from net.gateway_control" ;;
  log) cat "$GW_LOG" ;;
  player) $PSQL -F' ' -c "select name, round(x::numeric,2), round(y::numeric,2), round(z::numeric,2), 'yaw='||round(yaw::numeric,1), 'pitch='||round(pitch::numeric,1), 'chunk='||chunk_x||','||chunk_z, 'gm='||gamemode, 'conn='||coalesce(conn_id::text,'-') from mc.player order by entity_id" ;;
  psql) shift; exec psql -X -h /tmp -p "$DBCRAFT_PGPORT" -U postgres dbcraft "$@" ;;
  *) echo "usage: $0 setup | start | stop | status | log | player | psql [args]"; exit 2 ;;
esac
