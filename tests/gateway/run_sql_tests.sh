#!/usr/bin/env bash
# The standard SQL suite (tests/sql/run.sh) on the gateway tests' own cluster (port 54555), in its own database, so it never touches another cluster.
# usage: tests/gateway/run_sql_tests.sh [pattern]
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-gw2} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54555} DBCRAFT_TESTDB=${DBCRAFT_TESTDB:-dbcraft_gwt}
exec tests/sql/run.sh "$@"
