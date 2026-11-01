#!/usr/bin/env bash
# usage: tests/bench/tick/parallel/scale_one.sh SCRIPT [SECONDS] [DATABASE]     scaling of one pgbench script over 1, 2, 3, 4 and 6 clients
set -euo pipefail
cd "$(dirname "$0")"
SC=$1; SECS=${2:-5}; DB=${3:-pgb}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres
PGB=/usr/lib/postgresql/16/bin/pgbench
base=""
printf '%s on database %s\n' "$SC" "$DB"
for c in 1 2 3 4 6; do
  tps=$($PGB -n -c "$c" -j "$c" -T "$SECS" -f "$SC.sql" "$DB" 2>&1 | awk '/^tps =/ {print $3}')
  if [ -z "$base" ]; then base=$tps; fi
  printf '  %d clients: %9.0f /s   speed-up x%.2f\n' "$c" "$tps" "$(echo "$tps / $base" | bc -l)"
done
