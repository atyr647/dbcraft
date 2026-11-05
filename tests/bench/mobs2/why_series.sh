#!/usr/bin/env bash
# CPU-only series of docs/WHY-MOBS-COST.md: fixed cost and per-mob slope (mobs in view / outside the view), the no-lane gradient (blocks scattered on the ground), two interleaved repetitions
# usage: tests/bench/mobs2/why_series.sh [OUTFILE]       env: PGHOST PGPORT PGUSER PGDATABASE; TICKS (100), WARM (150)
cd "$(dirname "$0")/../../.."
O=${1:-docs/why-mobs-results.txt}
echo "=== series (cpu only, $(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg)), ${TICKS:-100} ticks after ${WARM:-150} warm-up ticks + VACUUM ANALYZE, two interleaved repetitions" >> "$O"
run() {   # label mobs where scatter
  line=$(psql -X -q -At -v ON_ERROR_STOP=1 -v ticks=${TICKS:-100} -v warm=${WARM:-150} -v label="$1" -v mobs=$2 -v where=$3 -v reset=1 -v scatter=$4 -f tests/bench/mobs2/bench.sql 2>&1 | grep -E "cpu ms avg|ERROR" | tail -1)
  echo "$line" >> "$O"
}
for rep in 1 2; do
  echo "--- repetition $rep" >> "$O"
  for m in 0 500 2000 5000; do run "S-view-$m" $m view 0; done
  for m in 500 2000 5000; do run "S-ring-$m" $m ring 0; done
  for sc in 20 200 2000; do run "S-scatter$sc-view-2000" 2000 view $sc; done
done
echo "DONE series" >> "$O"
