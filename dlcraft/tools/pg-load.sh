#!/usr/bin/env bash
# Load the PostgreSQL implementation (pg/*.sql, plus bench/pg/*.sql) into database $1 (default dlbench).
set -euo pipefail
DB=${1:-dlbench}
cd "$(dirname "$0")/.."
P="psql -h 127.0.0.1 -p ${DLCRAFT_PGPORT:-54340} -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -tAc "select 1 from pg_database where datname='$DB'" | grep -q 1 || $P -d postgres -c "create database $DB"
for f in pg/[0-9]*.sql bench/pg/*.sql; do [ -f "$f" ] && $P -d "$DB" -f "$f" >/dev/null; done
echo "loaded into $DB"
