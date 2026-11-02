#!/usr/bin/env bash
# usage: split_all.sh OUTFILE      the whole split-by-function table of docs/PERF-MULTICORE.md (about ten minutes; the machine must be otherwise idle)
set -uo pipefail
cd "$(dirname "$0")/../../.."
OUT=${1:-/tmp/mc_split_all.txt}
: > "$OUT"
run() { echo "## $*" >> "$OUT"; bash tests/bench/multicore/split_run.sh "$@" 2>&1 | cut -c1-420 >> "$OUT"; }
for m in off inline split; do run "$m" 200 2000 160 50; done                  # 200 walkers, 2,000 awake mobs, a paced 20 Hz server
for m in off inline split; do SIDE=100 run "$m" 500 2000 100 0; done          # 500 walkers, 2,000 awake mobs, back to back
for m in off inline split; do SIDE=3 run "$m" 500 2000 100 0 1; done          # 500 crowded in 3x3 chunks, 2,000 mobs around them
echo "## done" >> "$OUT"
