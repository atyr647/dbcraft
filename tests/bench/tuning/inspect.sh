#!/usr/bin/env bash
# Start a throwaway copy of the golden data directory and print the table facts the storage parameters are based on.
# usage: tests/bench/tuning/inspect.sh [SQL_FILE]     (default: tests/bench/tuning/inspect.sql)   env: GOLD, INSPECT_DATA (default /tmp/dbcraft-pg-tune-insp), INSPECT_PORT (54473)
set -euo pipefail
cd "$(dirname "$0")/../../.."
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${INSPECT_DATA:-/tmp/dbcraft-pg-tune-insp}; PORT=${INSPECT_PORT:-54473}
SQLF=${1:-tests/bench/tuning/inspect.sql}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true' EXIT
PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft psql -X -f "$SQLF"
