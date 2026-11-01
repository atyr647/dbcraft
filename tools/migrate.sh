#!/usr/bin/env bash
# usage: tools/migrate.sh [--fresh]    applies sql/*.sql in order to $PGDATABASE (or the dev cluster via tools/pg-dev.sh)
# --fresh drops and recreates the dbcraft schemas first.
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL=${DBCRAFT_PSQL:-psql}
if [ "${1:-}" = "--fresh" ]; then
  $PSQL -X -q -v ON_ERROR_STOP=1 -c "drop schema if exists ref, proto, mc, net cascade"
fi
for f in sql/*.sql; do
  echo "== $f"
  $PSQL -X -q -v ON_ERROR_STOP=1 -f "$f"
done
