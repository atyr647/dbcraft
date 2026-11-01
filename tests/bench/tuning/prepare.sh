#!/usr/bin/env bash
# Build the "golden" data directory every tuning trial starts from: the e2e database (tests/e2e/setup.sh) plus a WARM flat world covering the area the bots
# walk in (every chunk generated and its packet cached), vacuumed and frozen, then the cluster is stopped cleanly.
#
# usage: tests/bench/tuning/prepare.sh [SIDE_CHUNKS=100] [VIEW=10]     env: GOLD (data dir, default /tmp/dbcraft-pg-tune-gold), GOLD_PORT (default 54471)
set -euo pipefail
cd "$(dirname "$0")/../../.."
SIDE=${1:-100}; VIEW=${2:-10}
export DBCRAFT_PGDATA=${GOLD:-/tmp/dbcraft-pg-tune-gold} DBCRAFT_PGPORT=${GOLD_PORT:-54471}
tests/e2e/setup.sh | tail -1
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=dbcraft
LO=$((-VIEW - 1)); HI=$((SIDE + VIEW))
echo "generating and caching chunks $LO..$HI (square) ..."
S=$(mktemp); trap 'rm -f "$S"' EXIT
for x in $(seq $LO $HI); do
  echo "select count(*) from (select mc.generate_flat('minecraft:overworld', $x, z) from generate_series($LO, $HI) z) g;"
  echo "select count(mc.chunk_body_cached('minecraft:overworld', $x, z)) from generate_series($LO, $HI) z;"
done > "$S"
T0=$(date +%s)
psql -X -q -At -o /dev/null -f "$S"
echo "  took $(( $(date +%s) - T0 )) s"
psql -X -q -At -c "select 'chunks: ' || count(*) from mc.chunk" -c "select 'cached packets: ' || count(*) from mc.chunk_cache"
psql -X -q -c "vacuum (freeze, analyze)" -c "checkpoint"
psql -X -q -At -c "select 'database size: ' || pg_size_pretty(pg_database_size('dbcraft'))"
tools/pg-dev.sh stop
echo "golden data directory ready: $DBCRAFT_PGDATA"
