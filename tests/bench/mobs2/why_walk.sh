#!/usr/bin/env bash
# docs/WHY-MOBS-COST.md section 7: what the cost is if dbcraft's cows walked as much as vanilla's (walk probability 0 = every goal a stand; 0.38 = about 25 % of the time walking; 0.6 = the default, 45 %;
# 1.0 = always), 2,000 cows, in view and on the ring, CPU only, two interleaved repetitions.      usage: tests/bench/mobs2/why_walk.sh [OUTFILE]
cd "$(dirname "$0")/../../.."
O=${1:-docs/why-mobs-results.txt}
echo "=== walking share (cpu only, $(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg)), ${TICKS:-100} ticks after ${WARM:-150} warm-up" >> "$O"
run() {   # label mobs where walk
  line=$(psql -X -q -At -v ON_ERROR_STOP=1 -v ticks=${TICKS:-100} -v warm=${WARM:-150} -v label="$1" -v mobs=$2 -v where=$3 -v walk=$4 -v reset=1 -f tests/bench/mobs2/bench.sql 2>&1 | grep -E "cpu ms avg|ERROR" | tail -1)
  echo "$line" >> "$O"
}
for rep in 1 2; do
  for w in 0.0 0.38 0.6 1.0; do
    run "W-ring-2000-walk$w" 2000 ring $w
    run "W-view-2000-walk$w" 2000 view $w
  done
done
echo "DONE walk" >> "$O"
