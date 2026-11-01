#!/usr/bin/env bash
# usage: tests/bench/tick/ab.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [ROUNDS] [TICKS] [DB_A] [DB_B]
# Alternates runs of tests/bench/tick/run.sh against two databases that differ only in the SQL under test (A first, then B, ROUNDS times) and prints the
# median and the min..max of every round's wall avg, wall p99, on-CPU avg and on-CPU p99.  Interleaving cancels most of the drift caused by other jobs on the machine.
# Default A = dbcraft_base (the frozen baseline clone), B = dbcraft.  Make B from A with: createdb -T A B  (no connections to A), then apply the change to B.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; ROUNDS=${4:-5}; TICKS=${5:-100}; A=${6:-dbcraft_base}; B=${7:-dbcraft}
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
for r in $(seq 1 "$ROUNDS"); do
  for db in "$A" "$B"; do
    DBCRAFT_BENCH_DB=$db tests/bench/tick/run.sh "$N" "$SIDE" "$FRAC" "$TICKS" "$db" | head -1 >> "$OUT"
  done
done
python3 - "$OUT" "$A" "$B" <<'E'
import re, sys, statistics as st
rows = {}
for line in open(sys.argv[1]):
    m = re.match(r'(\S+) .*?wall avg ([\d.]+) p10 ([\d.]+) p50 ([\d.]+) p95 ([\d.]+) p99 ([\d.]+) max ([\d.]+) \| cpu avg ([\d.]+) p10 ([\d.]+) p50 ([\d.]+) p95 ([\d.]+) p99 ([\d.]+) .*phases process ([\d.]+) game ([\d.]+) blocks ([\d.]+) chunks ([\d.]+) drain ([\d.]+)', line)
    if m:
        rows.setdefault(m.group(1), []).append([float(x) for x in m.groups()[1:]])
names = ['wall avg', 'wall p10', 'wall p50', 'wall p99', 'cpu avg', 'process', 'game', 'blocks', 'chunks', 'drain']
idx = [0, 1, 2, 5, 7, 11, 12, 13, 14, 15]
print(f"{'':14s}" + ''.join(f'{n:>22s}' for n in names))
for db in (sys.argv[2], sys.argv[3]):
    r = rows.get(db, [])
    cells = []
    for i in idx:
        v = [x[i] for x in r]
        cells.append(f"{st.median(v):7.1f} ({min(v):.1f}-{max(v):.1f})" if v else 'n/a')
    print(f'{db:14s}' + ''.join(f'{c:>22s}' for c in cells) + f'   [{len(r)} runs]')
E
