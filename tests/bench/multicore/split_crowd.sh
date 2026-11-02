#!/usr/bin/env bash
# usage: split_crowd.sh OUTFILE      500 players crowded in 3x3 chunks with 2,000 mobs around them, 300 ticks (the first announcement burst is a seconds-long tick: it must be outlived)
set -uo pipefail
cd "$(dirname "$0")/../../.."
OUT=${1:-/tmp/mc_split_crowd.txt}
: > "$OUT"
run() { echo "## $*" >> "$OUT"; SIDE=3 bash tests/bench/multicore/split_run.sh "$@" 2>&1 | cut -c1-420 >> "$OUT"; }
for m in off split inline; do run "$m" 500 2000 300 0 1; done
echo "## done" >> "$OUT"
