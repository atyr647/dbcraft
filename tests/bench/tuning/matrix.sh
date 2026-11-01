#!/usr/bin/env bash
# Run several configurations, interleaved over repetitions (round 1 of every config, then round 2 ...), so that machine-load drift hits all of them alike.
#
# usage: tests/bench/tuning/matrix.sh TAG REPS SECONDS PLAYERS MOVING_FRACTION label=conf[,conf...][|VAR=value;VAR=value] [...]
#   e.g.  tests/bench/tuning/matrix.sh r1 3 75 200 0.25 ref=ref stock=stock 'qav=ref,av_fast|APPLY=tests/bench/tuning/apply/q_av.sql' 'stall=ref|STALL=1'
#   after '|': environment variables for run.sh for that label only (APPLY, STALL, STALL_GUARD, DIAG, WALSTAT ...), separated by ';'
# Appends one line per trial to tests/bench/tuning/results/matrix_TAG.txt and "label dir" pairs to matrix_TAG.names; aggregate with table.py TAG.
set -uo pipefail
cd "$(dirname "$0")/../../.."
TAG=$1; REPS=$2; SECS=$3; N=$4; FRAC=$5; shift 5
OUTD=tests/bench/tuning/results; mkdir -p "$OUTD"
for r in $(seq 1 "$REPS"); do
  for spec in "$@"; do
    label=${spec%%=*}; rest=${spec#*=}; confs=${rest%%|*}; envs=""
    if [[ "$rest" == *"|"* ]]; then envs=${rest#*|}; fi
    name="${TAG}_${label}_r${r}"
    (
      IFS=';' read -ra EV <<< "$envs"
      for e in "${EV[@]}"; do [ -n "$e" ] && export "$e"; done
      tests/bench/tuning/run.sh "$name" "$confs" "$N" "$FRAC" "$SECS" 2>/dev/null | tail -1
    ) | tee -a "$OUTD/matrix_$TAG.txt"
    echo "$label $name" >> "$OUTD/matrix_$TAG.names"
  done
done
