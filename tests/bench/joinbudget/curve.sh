#!/usr/bin/env bash
# The trade-off curve of the join budget: budget (headroom ms), maximum wait (s) against worst tick and time until everybody is in.
# usage: tests/bench/joinbudget/curve.sh OUTFILE [REPS]      each line of OUTFILE is one run (tests/bench/joinbudget/run.py output, JSON)
# Runs are INTERLEAVED across the configurations (config A, B, C, A, B, C ...) so drift of the machine hits all of them.
set -uo pipefail
cd "$(dirname "$0")/../../.."
OUT=${1:-/tmp/joinbudget-curve.jsonl}; REPS=${2:-2}
: > "$OUT"
CONFIGS=(
  "--joiners 200 --online 200 --budget off --label off"
  "--joiners 200 --online 200 --budget 25 --maxwait 10 --label b25w10"
  "--joiners 200 --online 200 --budget 25 --maxwait 20 --label b25w20"
  "--joiners 200 --online 200 --budget 25 --maxwait 28 --label b25w28"
  "--joiners 200 --online 200 --budget 10 --maxwait 20 --label b10w20"
  "--joiners 200 --online 200 --budget 60 --maxwait 20 --label b60w20"
  "--joiners 200 --online 0   --budget off --label empty-off"
  "--joiners 200 --online 0   --budget 25 --maxwait 20 --label empty-b25w20"
  "--joiners 500 --online 200 --budget off --label 500-off"
  "--joiners 500 --online 200 --budget 25 --maxwait 20 --label 500-b25w20"
  "--joiners 500 --online 200 --budget 25 --maxwait 28 --label 500-b25w28"
  "--joiners 50  --online 200 --budget off --label 50-off"
  "--joiners 50  --online 200 --budget 25 --maxwait 20 --label 50-b25w20"
  "--joiners 50  --online 0   --budget off --label 50-empty-off"
  "--joiners 50  --online 0   --budget 25 --maxwait 20 --label 50-empty-b25w20"
  "--joiners 500 --online 0   --budget off --label 500-empty-off"
  "--joiners 500 --online 0   --budget 25 --maxwait 20 --label 500-empty-b25w20"
)
for rep in $(seq 1 "$REPS"); do
  for c in "${CONFIGS[@]}"; do
    # shellcheck disable=SC2086
    python3 tests/bench/joinbudget/run.py $c --json --max-ticks 4000 >> "$OUT" 2>>"$OUT.err" || echo "run failed: $c" >> "$OUT.err"
  done
done
echo done >> "$OUT.err"
