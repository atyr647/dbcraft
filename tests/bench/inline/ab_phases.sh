#!/usr/bin/env bash
# usage: tests/bench/inline/ab_phases.sh DB_A DB_B [ROUNDS] [TICKS] [PLAYERS] [FRACTION]
# Alternates tests/bench/tick/run.sh against two databases (A, B, A, B ...) and prints EVERY run: on-CPU avg and the per-phase averages (process / game /
# blocks / chunks / drain), then the median of each column per database.  The chunk phase is the noisiest on a shared machine (see docs/PERF-INLINE.md): compare
# the phase your change touches, and the on-CPU total only when the phases agree.
set -euo pipefail
cd "$(dirname "$0")/../../.."
A=${1:?db a}; B=${2:?db b}; ROUNDS=${3:-7}; TICKS=${4:-100}; N=${5:-500}; FRAC=${6:-1.0}
export DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54329}
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
for r in $(seq 1 "$ROUNDS"); do
  for db in "$A" "$B"; do
    DBCRAFT_BENCH_DB=$db tests/bench/tick/run.sh "$N" 100 "$FRAC" "$TICKS" "$db" | head -1 >> "$OUT"
  done
done
python3 -I - "$OUT" "$A" "$B" <<'E'
import re, sys, statistics as st
rows = {}
for line in open(sys.argv[1]):
    m = re.match(r'(\S+) .*?wall avg ([\d.]+).*?p99 ([\d.]+) max.*?\| cpu avg ([\d.]+).*?phases process ([\d.]+) game ([\d.]+) blocks ([\d.]+) chunks ([\d.]+) drain ([\d.]+)', line)
    if m: rows.setdefault(m.group(1), []).append([float(x) for x in m.groups()[1:]])
cols = ['wall avg', 'wall p99', 'cpu avg', 'process', 'game', 'blocks', 'chunks', 'drain']
print('%-16s' % '' + ''.join('%10s' % c for c in cols))
n = max(len(v) for v in rows.values())
for i in range(n):
    for db in (sys.argv[2], sys.argv[3]):
        if i < len(rows.get(db, [])): print('%-16s' % (db + ' #%d' % (i + 1)) + ''.join('%10.1f' % x for x in rows[db][i]))
print('-' * (16 + 10 * len(cols)))
for db in (sys.argv[2], sys.argv[3]):
    r = rows.get(db, [])
    print('%-16s' % (db + ' median') + ''.join('%10.1f' % st.median([x[j] for x in r]) for j in range(len(cols))))
    print('%-16s' % (db + ' min..max') + ''.join('%10s' % ('%.0f-%.0f' % (min(x[j] for x in r), max(x[j] for x in r))) for j in range(len(cols))))
E
