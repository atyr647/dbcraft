#!/usr/bin/env bash
# Concurrent compression throughput with pgbench: packets per second with 1, 2 and 4 clients (each client = one backend = one core).
#   PGHOST=/tmp PGPORT=54433 PGUSER=postgres PGDATABASE=dbcraft_zlib tests/bench/native/throughput.sh [SECONDS=6]
# Needs tests/bench/native/setup.sql to have been run.  Each line: transactions per second = real chunk packets (or 4 KiB fragments) compressed per second.
set -euo pipefail
cd "$(dirname "$0")"
T=${1:-6}
PGBENCH=$(ls /usr/lib/postgresql/*/bin/pgbench | sort -V | tail -1)
for script in pgb_libdeflate_l1 pgb_zlib_l6 pgb_sql_deflate pgb_edit_fragment; do
  for c in 1 2 4; do
    printf '%-20s clients=%d  load=%s  ' "$script" "$c" "$(cut -d' ' -f1 /proc/loadavg)"
    "$PGBENCH" -n -f "$script.sql" -c "$c" -j "$c" -T "$T" 2>&1 | grep -E "^tps" | sed 's/ (without.*//'
  done
done
