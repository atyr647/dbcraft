#!/usr/bin/env bash
# the tests the empty-tick change touches, each through tests/sql/prun.sh with its own template database       usage: tests/bench/mobs2/why_tests.sh      env: DBCRAFT_PGDATA DBCRAFT_PGPORT DBCRAFT_TESTDB
cd "$(dirname "$0")/../../.."
for p in entity idle_tick quiet_gate; do
  echo "##### prun $p"
  JOBS=${JOBS:-2} tests/sql/prun.sh "$p" 2>&1 | grep -v "^ok  "
done
echo "##### done"
