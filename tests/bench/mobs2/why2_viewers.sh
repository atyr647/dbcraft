#!/usr/bin/env bash
# docs/WHY-MOBS-COST.md section 10, lever 4: the cost of the viewer refresh and the pickup scan with many players standing still and a few resting items (so the tick is not empty).
# OLDDB = a database with the entity files of the tree before the change applied; NEWDB = the tree.     usage: tests/bench/mobs2/why2_viewers.sh [OUTFILE]     env: PGHOST PGPORT PGUSER OLDDB NEWDB
cd "$(dirname "$0")/../../.."
O=${1:-docs/why-mobs-results-2.txt}
echo "=== viewers (cpu only, $(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg)): 5 resting items, N players standing still, 300 ticks after 100 warm-up" >> "$O"
for rep in 1 2; do
  for v in 1 50 200; do
    for db in ${OLDDB:-olddb} ${NEWDB:-dbcraft_dev}; do
      line=$(PGDATABASE=$db psql -X -q -At -v ON_ERROR_STOP=1 -v ticks=300 -v warm=100 -v label="$db/players-$v" -v mobs=0 -v items=5 -v where=view -v reset=0 -v viewers=$v -f tests/bench/mobs2/bench.sql 2>&1 | grep -E "cpu ms avg|ERROR" | tail -1)
      echo "$line" >> "$O"
    done
  done
done
echo "DONE viewers" >> "$O"
