#!/usr/bin/env bash
# dbcraft only, steady state: old and new alternating, 3 repetitions, warm-up of 150 ticks (the first 60 ticks of a population are the transient in which every mob gets its first goal and
# enters its lane; a window that starts at tick 31 includes it), 100 measured ticks.   usage: tests/bench/mobs2/steady.sh OUTFILE [REPS] [SCENARIOS]
# env: PGHOST PGPORT PGUSER, OLD_DB (dbcraft), NEW_DB (dbcraft_dev)
set -uo pipefail
cd "$(dirname "$0")/../../.."
out=$1; reps=${2:-3}; scen=${3:-500v 2000v 5000v 2000n 5000n 5000i}
for rep in $(seq 1 "$reps"); do
  for code in $scen; do
    PGDATABASE=${OLD_DB:-dbcraft} tests/bench/mobs2/run_one.sh "$code" "$rep" old "$out" -v warm=150 2>&1 | grep -v NOTICE
    PGDATABASE=${NEW_DB:-dbcraft_dev} tests/bench/mobs2/run_one.sh "$code" "$rep" new "$out" -v warm=150 2>&1 | grep -v NOTICE
  done
done
