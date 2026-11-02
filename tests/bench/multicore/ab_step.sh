#!/usr/bin/env bash
# usage: ab_step.sh OLD.sql NEW.sql [ROUNDS]   env: PGHOST/PGPORT/PGUSER, PGDATABASE (a database a bench_tick.sql run populated)
# Alternates two definitions of mc.entity_lane_step on the SAME population (phases_lane.sql runs ticks 5000.. which is after the bench's own ticks) and prints the step cost of each.
set -euo pipefail
DIR="$(dirname "$0")"
OLD=$1; NEW=$2; ROUNDS=${3:-3}
first=${FIRST0:-10000}
for r in $(seq 1 "$ROUNDS"); do
  for v in "$OLD" "$NEW"; do
    psql -X -q -v ON_ERROR_STOP=1 -f "$v" > /dev/null
    printf '%s: ' "$v"
    psql -X -q -At -F ' ' -v first=$first -f "$DIR/phases_lane.sql" | grep -E '^(a|b) lane' | tr '\n' ' '
    echo
    first=$((first + 100))
  done
done
