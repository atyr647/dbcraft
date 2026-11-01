#!/usr/bin/env bash
# Interleaved comparison: ROUNDS rounds; in every round the variants run in a freshly shuffled order, so drift of the shared machine's load
# does not favour a variant.   usage: tools/pgbuild/bench_all.sh ROUNDS "A B C D" OUTFILE
set -euo pipefail
cd "$(dirname "$0")/../.."
ROUNDS=${1:-5}; VARIANTS=${2:-A B C D}; OUT=${3:-/tmp/pgbuild/runtime-raw.txt}
mkdir -p "$(dirname "$OUT")"; : > "$OUT"
for v in $VARIANTS; do tools/pgbuild/cluster.sh "$v" start 2>/dev/null || true; done
for r in $(seq 1 "$ROUNDS"); do
  for v in $(shuf -e $VARIANTS); do
    echo "round $r variant $v (load $(cut -d' ' -f1 /proc/loadavg))"
    tools/pgbuild/bench_round.sh "$v" "$r" "$OUT"
  done
done
python3 tools/pgbuild/analyze.py "$OUT" "$VARIANTS"
