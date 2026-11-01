#!/usr/bin/env bash
# Start/stop a throwaway local PostgreSQL for development.  Usage: tools/pg-dev.sh start|stop|psql|reset
set -euo pipefail
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
DATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg}
PORT=${DBCRAFT_PGPORT:-54329}
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
case "${1:-}" in
  start)
    if [ ! -d "$DATA/base" ]; then
      mkdir -p "$DATA"; [ "$(id -u)" = 0 ] && chown postgres "$DATA"
      as_pg "$PGBIN/initdb -D $DATA -A trust -E UTF8 >/dev/null"
    fi
    if ! as_pg "$PGBIN/pg_ctl -D $DATA status" >/dev/null 2>&1; then          # already running: nothing to do
      as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp -c fsync=off -c synchronous_commit=off -c max_connections=200' -l $DATA/log -w start" >/dev/null
    fi
    psql -h /tmp -p "$PORT" -U postgres -tAc "select 1 from pg_database where datname='dbcraft'" | grep -q 1 \
      || psql -h /tmp -p "$PORT" -U postgres -qc "create database dbcraft" ;;
  stop)  as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" ;;
  psql)  shift; exec psql -h /tmp -p "$PORT" -U postgres dbcraft "$@" ;;
  reset) "$0" stop 2>/dev/null || true; rm -rf "$DATA"; "$0" start ;;
  *) echo "usage: $0 start|stop|psql|reset"; exit 2 ;;
esac
