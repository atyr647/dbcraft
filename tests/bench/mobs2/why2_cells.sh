#!/usr/bin/env bash
# docs/WHY-MOBS-COST.md section 10: the cells of the first round again, before / after the vanilla-like AI and the levers.  CPU only, two interleaved repetitions.
#   OLD  = the old behaviour:  dbcraft.entity_ai = wander, dbcraft.entity_lane_retry = 1 (retry a refused lane every tick)
#   RETRY = wander + the negative cache (isolates lever 1)
#   NEW  = the defaults: vanilla-like AI, negative cache
# usage: tests/bench/mobs2/why2_cells.sh [OUTFILE] [CELLS...]     env: PGHOST PGPORT PGUSER PGDATABASE; TICKS (100), WARM (400)
cd "$(dirname "$0")/../../.."
O=${1:-docs/why-mobs-results-2.txt}; shift
cells=("$@"); [ ${#cells[@]} -eq 0 ] && cells=("view:2000:0" "ring:2000:0" "view:500:0" "view:5000:0" "ring:5000:0" "view:2000:20" "view:2000:200" "view:2000:2000")
echo "=== second round (cpu only, $(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg)), ${TICKS:-100} ticks after ${WARM:-400} warm-up ticks + VACUUM ANALYZE" >> "$O"
run() {   # variant opts where mobs scatter
  line=$(PGOPTIONS="$2" psql -X -q -At -v ON_ERROR_STOP=1 -v ticks=${TICKS:-100} -v warm=${WARM:-400} -v label="$1/$3-$4-s$5" -v mobs=$4 -v where=$3 -v reset=1 -v scatter=$5 -f tests/bench/mobs2/bench.sql 2>&1 | grep -E "cpu ms avg|ERROR" | tail -1)
  echo "$line" >> "$O"
}
for rep in 1 2; do
  echo "--- repetition $rep" >> "$O"
  for c in "${cells[@]}"; do
    IFS=: read where mobs scatter <<< "$c"
    run OLD "-c dbcraft.entity_ai=wander -c dbcraft.entity_lane_retry=1" $where $mobs $scatter
    [ "$scatter" != 0 ] && run RETRY "-c dbcraft.entity_ai=wander" $where $mobs $scatter
    run NEW "" $where $mobs $scatter
  done
done
echo "DONE round2" >> "$O"
