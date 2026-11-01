#!/usr/bin/env bash
# Run several configurations, interleaved over repetitions (round 1 of every config, then round 2 ...), so that machine-load drift hits all of them alike.
#
# usage: tests/bench/tuning/matrix.sh TAG REPS SECONDS PLAYERS MOVING_FRACTION label=conf[,conf...] [label=conf ...]
#   e.g.  tests/bench/tuning/matrix.sh r1 3 75 200 0.25 ref=ref stock=stock sync_on=ref,sync_on
# Appends one line per trial to tests/bench/tuning/results/matrix_TAG.txt and "label dir" pairs to matrix_TAG.names; aggregate with table.py TAG.
set -uo pipefail
cd "$(dirname "$0")/../../.."
TAG=$1; REPS=$2; SECS=$3; N=$4; FRAC=$5; shift 5
OUTD=tests/bench/tuning/results; mkdir -p "$OUTD"
for r in $(seq 1 "$REPS"); do
  for spec in "$@"; do
    label=${spec%%=*}; confs=${spec#*=}
    name="${TAG}_${label}_r${r}"
    tests/bench/tuning/run.sh "$name" "$confs" "$N" "$FRAC" "$SECS" 2>/dev/null | tail -1 | tee -a "$OUTD/matrix_$TAG.txt"
    echo "$label $name" >> "$OUTD/matrix_$TAG.names"
  done
done
