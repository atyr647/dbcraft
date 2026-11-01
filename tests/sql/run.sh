#!/usr/bin/env bash
# usage: [DBCRAFT_TESTDB=name] tests/sql/run.sh [pattern]   Builds a fresh database "dbcraft_test" on the dev cluster, migrates, loads reference data, runs tests/sql/NN_*.sql.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54329}
tools/pg-dev.sh start >/dev/null 2>&1 || true
ADMIN="psql -X -q -h /tmp -p $DBCRAFT_PGPORT -U postgres"
TESTDB=${DBCRAFT_TESTDB:-dbcraft_test}
$ADMIN -d postgres -c "drop database if exists $TESTDB" -c "create database $TESTDB"
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=$TESTDB
tools/migrate.sh --fresh >/dev/null
if [ -d "${DBCRAFT_REPORTS:-/home/user/atyr647/adacraft/generated/26.3/reports}" ]; then tools/load_reports.py; else echo "NOTE: no reports found; tests needing ref.* data will fail"; fi
fail=0
for f in tests/sql/[0-9]*${1:-}*.sql; do
  echo "--- $f"
  if out=$(psql -X -q -v ON_ERROR_STOP=1 -f tests/sql/_harness.sql -f "$f" 2>&1); then
    echo "$out" | grep -c "NOTICE:  ok" | xargs -I{} echo "PASS $f ({} checks)"
  else
    echo "$out" | grep -E "FAIL|ERROR|LINE" | sed 's/^psql:[^ ]* //'; echo "FAILED $f"; fail=1
  fi
done
exit $fail
