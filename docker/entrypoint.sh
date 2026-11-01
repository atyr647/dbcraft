#!/usr/bin/env bash
# Wrapper around the official image's entrypoint: starts PostgreSQL (docker-entrypoint.sh initialises the data directory on first start and runs
# /docker-entrypoint-initdb.d/10-dbcraft.sh), and, when DBCRAFT_DEV_GATEWAY=1, keeps the development gateway (call net.run) running next to it.
#
# The gateway is a stored procedure that holds one connection open for as long as it runs; this loop restarts it if it ends (a Python error stops the procedure,
# the backend survives).  Stopping it on purpose: update net.gateway_control set stop = true;  (the loop honours that and does not restart it).
set -euo pipefail

gateway_loop() {
  export PGUSER=${POSTGRES_USER:-postgres} PGDATABASE=${POSTGRES_DB:-postgres} PGHOST=/var/run/postgresql
  until pg_isready -q -h "$PGHOST"; do sleep 1; done
  # the first pg_isready can come from the temporary server that initialises the data directory; wait until the dbcraft schema exists and stays up
  until psql -X -q -At -c "select 1 from pg_namespace where nspname = 'net'" 2>/dev/null | grep -q 1; do sleep 2; done
  while true; do
    stop=$(psql -X -q -At -c "select stop from net.gateway_control" 2>/dev/null || echo f)
    if [ "$stop" = "t" ]; then echo "dbcraft: gateway stopped on request (net.gateway_control.stop)"; sleep 5; continue; fi
    echo "dbcraft: starting the development gateway on port ${DBCRAFT_GATEWAY_PORT:-25565}"
    psql -X -q -v ON_ERROR_STOP=1 -c "call net.run(${DBCRAFT_GATEWAY_PORT:-25565})" || echo "dbcraft: gateway ended with an error, restarting in 2 s"
    sleep 2
  done
}

if [ "${DBCRAFT_DEV_GATEWAY:-0}" = 1 ] && [ "${1:-}" = "postgres" ]; then
  gateway_loop &
fi
exec docker-entrypoint.sh "$@"
