#!/usr/bin/env bash
# dbcraft only, steady state: old and new alternating, REPS repetitions, warm-up of 150 ticks then VACUUM ANALYZE then 100 measured ticks (tests/bench/mobs2/bench.sql); for the
# walking scenarios also with every mob walking all the time (walk1).   usage: tests/bench/mobs2/steady.sh OUTFILE [REPS] [SCENARIOS]
# env: PGHOST PGPORT PGUSER, OLD_DB (dbcraft), NEW_DB (dbcraft_dev)
set -uo pipefail
cd "$(dirname "$0")/../../.."
out=$1; reps=${2:-3}; scen=${3:-500v 2000v 5000v 2000n 5000n 5000i}
for rep in $(seq 1 "$reps"); do
  for code in $scen; do
    PGDATABASE=${OLD_DB:-dbcraft} tests/bench/mobs2/run_one.sh "$code" "$rep" old "$out" -v warm=150 2>&1 | grep -v NOTICE
    PGDATABASE=${NEW_DB:-dbcraft_dev} tests/bench/mobs2/run_one.sh "$code" "$rep" new "$out" -v warm=150 2>&1 | grep -v NOTICE
    case "$code" in 2000v|5000v)
      PGDATABASE=${OLD_DB:-dbcraft} tests/bench/mobs2/run_one.sh "$code" "$rep" old-walk1 "$out" -v warm=150 -v walk=1.0 2>&1 | grep -v NOTICE
      PGDATABASE=${NEW_DB:-dbcraft_dev} tests/bench/mobs2/run_one.sh "$code" "$rep" new-walk1 "$out" -v warm=150 -v walk=1.0 2>&1 | grep -v NOTICE ;;
    esac
  done
done
