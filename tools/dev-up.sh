#!/usr/bin/env bash
# Start the development PostgreSQL cluster and the gateway.  The Rust gateway is used when it is built (gateway/build.sh); otherwise the PL/Python development
# gateway (the stored procedure net.run, offline mode only).  Idempotent: a gateway that is already running is left alone.
#
# usage: tools/dev-up.sh            environment: DBCRAFT_PORT (default 25565), DBCRAFT_GATEWAY=rust|plpython (default: rust when built)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh
mkdir -p "$DBCRAFT_LOG" "$DBCRAFT_RUN"
tools/pg-dev.sh start
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=dbcraft
if [ "$(psql -X -At -c "select count(*) from ref.block_state" 2>/dev/null || echo 0)" != 35723 ]; then
  echo "the database is not set up: run tools/bootstrap.sh first"; exit 1
fi

listening() { python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(0.3)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); s.close()
except OSError: sys.exit(1)
PY
}
PORT=$DBCRAFT_PORT
KIND=${DBCRAFT_GATEWAY:-}
if [ -z "$KIND" ]; then if [ -x gateway/target/dbcraft-gateway ]; then KIND=rust; else KIND=plpython; fi; fi

if listening "$PORT"; then echo "something already listens on port $PORT: leaving it alone"; else
  case "$KIND" in
    rust)
      [ -x gateway/target/dbcraft-gateway ] || { echo "gateway not built: run tools/bootstrap.sh or gateway/build.sh"; exit 1; }
      DBCRAFT_GW_DATABASE_URL="host=/tmp port=$DBCRAFT_PGPORT user=postgres dbname=dbcraft" DBCRAFT_GW_LISTEN="0.0.0.0:$PORT" \
        nohup gateway/target/dbcraft-gateway >"$DBCRAFT_LOG/gateway.log" 2>&1 &
      echo $! > "$DBCRAFT_RUN/gateway.pid" ;;
    plpython)
      psql -X -q -At -c "update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0" >/dev/null
      ( nohup psql -X -q -At -c "call net.run($PORT)" >"$DBCRAFT_LOG/gateway.log" 2>&1 & echo $! > "$DBCRAFT_RUN/gateway.pid" ) ;;
    *) echo "DBCRAFT_GATEWAY must be rust or plpython"; exit 2 ;;
  esac
  echo "$KIND" > "$DBCRAFT_RUN/gateway.kind"
  for _ in $(seq 1 100); do listening "$PORT" && break; sleep 0.2; done
  listening "$PORT" || { echo "the gateway did not start listening on $PORT, see $DBCRAFT_LOG/gateway.log"; exit 1; }
fi
echo
echo "dbcraft is up ($KIND gateway)."
echo "  Connect a Minecraft Java 26.3 client to:  localhost:$PORT   (offline mode: any name)"
echo "  Look at the world:   psql -h /tmp -p $PGPORT -U postgres dbcraft     e.g.  select * from mc.player;"
echo "  Stop:                tools/dev-down.sh"
