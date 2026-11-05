#!/usr/bin/env bash
# A/B of the visibility refresh in the walking bench, alternating in the same minutes (the machine is shared: only ratios of runs next to each other mean anything).
#   A = the neighbourhood version (mc.refresh_visibility_vis_nb, what the tick called before docs/PERF-VIS2.md), reached through a wrapper that replaces mc.refresh_visibility_vis
#   B = the boundary version of sql/909 (re-applied from the file)
# usage: DBCRAFT_PGPORT=... DBCRAFT_TESTDB=... tests/bench/game/vis_ab.sh REPS OUT [PLAYERS] [SIDE] [SPEEDS...]     e.g.  vis_ab.sh 2 docs/perf-vis2-results.txt 500 30 0.215 1.1
# one line per run: A|B, speed, tick ms, visibility ms (wall, from mc.tick_log) and the CPU of the backend per tick.  Needs a migrated database with the reference data (tests/sql/prun.sh builds one).
set -euo pipefail
cd "$(dirname "$0")/../../.."
REPS=${1:?reps}; OUT=${2:?out}; N=${3:-500}; SIDE=${4:-30}; shift 4 || shift $#
SPEEDS=${*:-0.215 1.1}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_TESTDB:-dbcraft_game}
for r in $(seq 1 "$REPS"); do
  for sp in $SPEEDS; do
    for side in A B; do
      if [ "$side" = A ]; then psql -X -q -v ON_ERROR_STOP=1 -f tests/bench/game/vis_ab_old.sql > /dev/null; else psql -X -q -v ON_ERROR_STOP=1 -f sql/909_vis_visibility.sql > /dev/null 2>&1; fi
      line=$(tests/bench/game/walk.sh "$sp" 70 "$side n=$N side=$SIDE" "$N" "$SIDE" | tr '\n' ' ')
      echo "$(date +%H:%M:%S) load $(cut -d' ' -f1 /proc/loadavg) $line" | tee -a "$OUT"
    done
  done
done
psql -X -q -v ON_ERROR_STOP=1 -f sql/909_vis_visibility.sql > /dev/null 2>&1
