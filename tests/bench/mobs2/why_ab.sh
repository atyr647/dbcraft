#!/usr/bin/env bash
# A/B of plan_cache_mode = force_generic_plan on mc.entity_physics_ids and mc.entity_tracker (planning of their statements happens on every call otherwise), alternating, two rounds, CPU only.
# A = as defined in the tree before the change (the settings are removed with ALTER FUNCTION ... RESET), B = force_generic_plan on both, C (why_ab.sh C) = on mc.entity_physics_ids only.      usage: tests/bench/mobs2/why_ab.sh [OUTFILE]
cd "$(dirname "$0")/../../.."
O=${1:-docs/why-mobs-results.txt}
echo "=== A/B generic plans for physics and tracker (cpu only, $(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg)), ${TICKS:-100} ticks after ${WARM:-150} warm-up" >> "$O"
setv() {
  if [ "$1" = A ]; then
    psql -X -q -c "alter function mc.entity_physics_ids(bigint) reset plan_cache_mode" -c "alter function mc.entity_tracker(bigint, int[]) reset plan_cache_mode" >/dev/null
  elif [ "$1" = C ]; then
    psql -X -q -c "alter function mc.entity_physics_ids(bigint) set plan_cache_mode = force_generic_plan" -c "alter function mc.entity_tracker(bigint, int[]) reset plan_cache_mode" >/dev/null
  else
    psql -X -q -c "alter function mc.entity_physics_ids(bigint) set plan_cache_mode = force_generic_plan" -c "alter function mc.entity_tracker(bigint, int[]) set plan_cache_mode = force_generic_plan" >/dev/null
  fi
}
run() {   # variant label mobs where scatter
  setv $1
  line=$(psql -X -q -At -v ON_ERROR_STOP=1 -v ticks=${TICKS:-100} -v warm=${WARM:-150} -v label="$1/$2" -v mobs=$3 -v where=$4 -v reset=1 -v scatter=$5 -f tests/bench/mobs2/bench.sql 2>&1 | grep -E "cpu ms avg|ERROR" | tail -1)
  echo "$line" >> "$O"
}
cells=("scatter20-view-2000 2000 view 20" "scatter200-view-2000 2000 view 200" "scatter2000-view-2000 2000 view 2000" "flat-view-2000 2000 view 0" "flat-ring-2000 2000 ring 0")
if [ -n "${FILTER:-}" ]; then sel=(); for c in "${cells[@]}"; do case "$c" in $FILTER*) sel+=("$c");; esac; done; cells=("${sel[@]}"); fi
for rep in 1 2; do
  for cell in "${cells[@]}"; do
    set -- $cell
    for v in ${VARIANTS:-A B}; do run $v $1 $2 $3 $4; done
  done
done
setv A
echo "DONE ab ${VARIANTS:-A B}" >> "$O"
