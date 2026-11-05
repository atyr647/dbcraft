#!/usr/bin/env bash
# usage: tools/migrate.sh [--fresh] [--dev-gateway]
#   applies sql/*.sql in order to $PGDATABASE (or whatever DBCRAFT_PSQL connects to)
#   --fresh          drops and recreates the dbcraft schemas first
#   An EXISTING database is not migrated by running this again (sql/210's view stops a second run): apply the files that changed.  For the world storage profile of
#   sql/950 (docs/PERF-DISK.md) that is  tools/compact_world.sh --apply-sql  (applies sql/245, 291, 950, then rewrites the stored rows and VACUUM FULLs).
#   --dev-gateway    also applies sql/optional/dev_gateway.sql (the PL/Python socket procedure net.run, offline mode) and sql/optional/dev_gateway_online.sql
#                    (net.run_online: the online-mode reference gateway); needs superuser and plpython3u
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL=${DBCRAFT_PSQL:-psql}
FRESH=0; DEV=0
for a in "$@"; do
  case "$a" in
    --fresh) FRESH=1 ;;
    --dev-gateway) DEV=1 ;;
    *) echo "usage: $0 [--fresh] [--dev-gateway]" >&2; exit 2 ;;
  esac
done
if [ "$FRESH" = 1 ]; then
  $PSQL -X -q -v ON_ERROR_STOP=1 -c "drop schema if exists ref, proto, mc, net cascade"
fi
for f in sql/*.sql; do
  echo "== $f"
  $PSQL -X -q -v ON_ERROR_STOP=1 -f "$f"
done
if [ "$DEV" = 1 ]; then
  echo "== sql/optional/dev_gateway.sql"
  $PSQL -X -q -v ON_ERROR_STOP=1 -f sql/optional/dev_gateway.sql
  echo "== sql/optional/dev_gateway_online.sql"
  $PSQL -X -q -v ON_ERROR_STOP=1 -f sql/optional/dev_gateway_online.sql
fi
