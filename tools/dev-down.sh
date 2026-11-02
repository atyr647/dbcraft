#!/usr/bin/env bash
# Stop the gateway and the development PostgreSQL cluster.   usage: tools/dev-down.sh [--keep-db]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=dbcraft
KIND=$(cat "$DBCRAFT_RUN/gateway.kind" 2>/dev/null || echo "")
if [ "$KIND" = plpython ] && psql -X -q -At -c "select 1" >/dev/null 2>&1; then
  psql -X -q -At -c "update net.gateway_control set stop = true" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    [ "$(psql -X -q -At -c "select count(*) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()" 2>/dev/null || echo 0)" = 0 ] && break
    sleep 0.25
  done
fi
if [ -f "$DBCRAFT_RUN/gateway.pid" ]; then
  pid=$(cat "$DBCRAFT_RUN/gateway.pid")
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done; fi
  rm -f "$DBCRAFT_RUN/gateway.pid" "$DBCRAFT_RUN/gateway.kind"
fi
echo "gateway stopped"
if [ "${1:-}" != "--keep-db" ]; then tools/pg-dev.sh stop 2>/dev/null && echo "database stopped" || echo "database was not running"; fi
