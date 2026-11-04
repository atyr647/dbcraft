#!/usr/bin/env bash
# One scenario at simulation distance 3 and 10, alternating: tests/bench/mobs2/simdist.sh CODE REPS     env: PGHOST PGPORT PGUSER PGDATABASE (a database made by tests/e2e/setup.sh)
set -uo pipefail
cd "$(dirname "$0")/../../.."
code=$1; reps=${2:-2}
for r in $(seq 1 "$reps"); do
  for sd in 3 10; do
    psql -X -q -c "update mc.server_property set value='$sd' where key='simulation-distance'" > /dev/null
    tests/bench/mobs2/run_one.sh "$code" "$r" "sim$sd" /dev/shm/mob3/simdist.txt -v warm=150 2>&1 | grep -v NOTICE | cut -c1-230
  done
done
