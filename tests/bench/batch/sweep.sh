#!/usr/bin/env bash
# The scenario sweep behind docs/PERF-BATCH.md: base against the batched tick (all default components) in every scenario, interleaved with rotating order.
#   usage: tests/bench/batch/sweep.sh [ROUNDS] [OUTDIR]       needs the benchmark database (see the doc); takes about 30 minutes
# Each scenario writes OUTDIR/<name>.log; the last lines of each log are the medians.
set -euo pipefail
cd "$(dirname "$0")/../../.."
R=${1:-5}; OUT=${2:-/tmp/dbcraft-batch-sweep}; mkdir -p "$OUT"
run() { name=$1; shift; echo "== $name: $*"; tests/bench/batch/ab.sh "$@" > "$OUT/$name.log" 2>&1; sed -n '/---- medians/,$p' "$OUT/$name.log" | sed 's/| KB\/tick [0-9.]* //' | cut -c1-300; }
#     name              impls                       players side frac mode   tx    ticks rounds
run s1_500_sparse_all   "base batched:all"           500  100 1.0 dither split 60 $R
run s2_500_sparse_20pc  "base batched:all"           500  100 0.2 dither split 60 $R
run s3_500_walk         "base batched:all"           500  100 1.0 walk   split 60 $R
run s4_500_crowded      "base batched:all"           500   30 1.0 dither split 60 $R
run s5_2000_sparse_all  "base batched:all"          2000  100 1.0 dither split 50 $R
run s6_2000_sparse_20pc "base batched:all"          2000  100 0.2 dither split 50 $R
run s7_500_idle         "base batched:all"           500  100 0.0 dither split 60 $R
run s8_0_players        "base batched:all"             0  100 0.0 dither split 60 $R
run s9_500_one_tx       "base batched:all"           500  100 1.0 dither one   60 $R
run s10_500_ref         "base batched:all batched:all,ref" 500 100 1.0 dither split 60 $R
