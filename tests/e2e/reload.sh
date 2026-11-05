#!/usr/bin/env bash
# Apply SQL files, in the order given, to the database the PG* environment variables name, then restart the dev gateway (vis_dev.sh) so its backend forgets cached plans.
# usage: PGHOST=/tmp PGPORT=.. PGUSER=postgres PGDATABASE=dbcraft DBCRAFT_PGPORT=.. VIS_GWPORT=.. tests/e2e/reload.sh sql/832_x.sql sql/833_y.sql ...
# Files that redefine one another's functions must be applied together in migration order (sql/833 drops functions that sql/837 defines).
cd "$(dirname "$0")/../.." || exit 1
for f in "$@"; do psql -X -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v NOTICE | head -5; done
tests/e2e/vis_dev.sh stop > /dev/null; tests/e2e/vis_dev.sh start > /dev/null
