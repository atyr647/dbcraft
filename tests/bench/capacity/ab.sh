#!/usr/bin/env bash
# Alternating A/B of the capacity bench on two databases (DB_A, DB_B: copies of one world that differ in the SQL under test), ROUNDS rounds, one summary line per run and a median per side.
# usage: DB_A=cap0 DB_B=cap2 [K=2] [BOUND=500] tests/bench/capacity/ab.sh PLAYERS SIDE FRAC TICKS ROUNDS
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-200}; SIDE=${2:-60}; FRAC=${3:-1.0}; TICKS=${4:-120}; ROUNDS=${5:-3}
OUT=$(mktemp)
for r in $(seq 1 "$ROUNDS"); do
  for side in A B; do
    db=$([ "$side" = A ] && echo "$DB_A" || echo "$DB_B")
    DBCRAFT_BENCH_DB=$db tests/bench/capacity/run.sh "$N" "$SIDE" "$FRAC" "$TICKS" "$side" | head -2 | tee -a "$OUT" | cut -c1-400
  done
done
python3 - "$OUT" <<'PY'
import re, sys, statistics
rows = {"A": [], "B": []}
for l in open(sys.argv[1]):
    m = re.match(r"(A|B) players.*wall avg ([\d.]+) p10 ([\d.]+) p50 ([\d.]+) p95 ([\d.]+) p99 ([\d.]+) max ([\d.]+) \| cpu avg ([\d.]+) p10 ([\d.]+) p50 ([\d.]+) p95 ([\d.]+) p99 ([\d.]+)", l)
    if m:
        rows[m.group(1)].append([float(x) for x in m.groups()[1:]])
names = ["wall avg", "wall p10", "wall p50", "wall p95", "wall p99", "wall max", "cpu avg", "cpu p10", "cpu p50", "cpu p95", "cpu p99"]
for s in "AB":
    if rows[s]:
        print(s, "median of %d: " % len(rows[s]) + "  ".join("%s %.1f [%.1f-%.1f]" % (n, statistics.median(c), min(c), max(c)) for n, c in zip(names, zip(*rows[s])) if n in ("wall avg", "cpu avg", "cpu p10", "cpu p50", "cpu p95")))
PY
rm -f "$OUT"
