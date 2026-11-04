#!/usr/bin/env bash
# run test files against the dev clone: tests/bench/mobs2/t.sh 940 541 ...    env: PGHOST PGPORT PGUSER (cluster of the dev), TDB (database, default mob3dev)
cd "$(dirname "$0")/../../.."
export PGHOST=/tmp PGPORT=${PGPORT:-57411} PGUSER=postgres
for n in "$@"; do
  f=$(ls tests/sql/${n}_*.sql | head -1)
  psql -X -q -d ${TDB:-mob3dev} -c "drop schema if exists t cascade" 2>/dev/null; s=$(date +%s)
  if PGDATABASE=${TDB:-mob3dev} timeout ${TMO:-900} psql -X -q -v ON_ERROR_STOP=1 -f tests/sql/_harness.sql -f "$f" > /dev/shm/mob3/t_$n.out 2>&1; then echo "PASS $f ($(grep -c 'NOTICE:  ok' /dev/shm/mob3/t_$n.out) checks, $(( $(date +%s) - s )) s)"; else echo "FAIL $f"; grep -E "FAIL|ERROR|LINE" /dev/shm/mob3/t_$n.out | head -8; fi
done
