#!/usr/bin/env bash
# Throwaway PostgreSQL 16 cluster for the dlcraft experiment, using dbcraft's own recommended settings (docker/postgresql.conf).
#   tools/pg.sh start [strict|relaxed|unsafe]   strict = synchronous_commit on; relaxed (default, dbcraft's setting) = off; unsafe = fsync off
#   tools/pg.sh stop | kill9 | reset | psql [args] | rss
set -euo pipefail
ROOT=${DLCRAFT_HOME:-/srv/dlcraft}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
DATA=$ROOT/pg
SOCK=$ROOT/sock
PORT=${DLCRAFT_PGPORT:-54340}
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
mode=${2:-relaxed}
opts() {
  local o="-p $PORT -k $SOCK -c listen_addresses=127.0.0.1 -c max_connections=100 -c shared_buffers=128MB -c effective_cache_size=4GB -c work_mem=64MB -c maintenance_work_mem=128MB \
-c full_page_writes=on -c wal_level=replica -c wal_compression=lz4 -c wal_buffers=16MB -c max_wal_size=4GB -c min_wal_size=512MB -c checkpoint_timeout=15min \
-c jit=off -c max_parallel_workers_per_gather=0 -c random_page_cost=1.1 -c autovacuum_naptime=10s -c idle_in_transaction_session_timeout=0"
  case "$mode" in
    strict)  o="$o -c fsync=on -c synchronous_commit=on" ;;
    relaxed) o="$o -c fsync=on -c synchronous_commit=off" ;;
    unsafe)  o="$o -c fsync=off -c synchronous_commit=off" ;;
    *) echo "mode: strict|relaxed|unsafe" >&2; exit 2 ;;
  esac
  echo "$o"
}
case "${1:-}" in
  start)
    mkdir -p "$ROOT" "$SOCK"; [ "$(id -u)" = 0 ] && chown postgres "$ROOT" "$SOCK"
    if [ ! -d "$DATA/base" ]; then as_pg "mkdir -p $DATA && $PGBIN/initdb -D $DATA -A trust -E UTF8 --locale=C.UTF-8 >/dev/null"; fi
    # "running" = the port answers (after kill -9 a dead postmaster lingers as an unreaped zombie that pg_ctl status still calls running)
    if ! "$PGBIN/pg_isready" -q -h 127.0.0.1 -p "$PORT"; then
      # a postmaster killed with SIGKILL stays a zombie here (nothing reaps it), and PostgreSQL refuses to start next to its pid: treat a zombie pid as stale
      if [ -f "$DATA/postmaster.pid" ]; then
        zp=$(head -1 "$DATA/postmaster.pid")
        if [ -z "$(ps -o stat= -p "$zp" 2>/dev/null | tr -d ' ')" ] || ps -o stat= -p "$zp" | grep -q '^Z'; then rm -f "$DATA/postmaster.pid" "$SOCK/.s.PGSQL.$PORT.lock" "$SOCK/.s.PGSQL.$PORT"; fi
      fi
      as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '$(opts)' -l $ROOT/pg.log -w start" >/dev/null
    fi
    psql -h 127.0.0.1 -p "$PORT" -U postgres -tAc "select 1 from pg_database where datname='dlcraft'" | grep -q 1 \
      || psql -h 127.0.0.1 -p "$PORT" -U postgres -qc "create database dlcraft" ;;
  stop)  as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" ;;
  kill9) kill -9 "$(head -1 $DATA/postmaster.pid)" ;;
  reset) "$0" stop 2>/dev/null || true; rm -rf "$DATA"; "$0" start "$mode" ;;
  psql)  shift; exec psql -h 127.0.0.1 -p "$PORT" -U postgres dlcraft "$@" ;;
  rss)   # resident memory of the postmaster and its children, MB
         pid=$(head -1 $DATA/postmaster.pid); for p in $pid $(pgrep -P $pid); do awk '/VmRSS/{print $2}' /proc/$p/status; done | awk '{s+=$2+0; if ($1+0>0) s+=0} {t+=$1} END{printf "%.0f\n", t/1024}' ;;
  *) echo "usage: $0 start|stop|kill9|reset|psql|rss"; exit 2 ;;
esac
