#!/usr/bin/env bash
# usage: tests/bench/tick/ab_ports.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION ROUNDS TICKS "LABEL_A PORT_A DB_A" "LABEL_B PORT_B DB_B" ...
# Interleaves runs of tests/bench/tick/run.sh against several (cluster, database) pairs (A, B, ..., A, B, ... ROUNDS times) and prints the median and the min..max of the
# wall average, p10, p50, p99 and the on-CPU average of every pair.  Used for the RAM-disk comparison (same database on a disk cluster and on a tmpfs cluster)
# and for runs where the two variants live on different clusters.  Notes the load average before every run.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=$1; SIDE=$2; FRAC=$3; ROUNDS=$4; TICKS=$5; shift 5
SPECS=("$@")
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
for r in $(seq 1 "$ROUNDS"); do
  for spec in "${SPECS[@]}"; do
    read -r LABEL PORT DB <<< "$spec"
    DBCRAFT_PGPORT=$PORT DBCRAFT_BENCH_DB=$DB tests/bench/tick/run.sh "$N" "$SIDE" "$FRAC" "$TICKS" "$LABEL" | head -1 >> "$OUT"
  done
done
python3 - "$OUT" <<'E'
import re, sys, statistics as st
rows = {}
for line in open(sys.argv[1]):
    m = re.match(r'(\S+) .*?load=([\d.]+) \| n \d+ \| wall avg ([\d.]+) p10 ([\d.]+) p50 ([\d.]+) p95 ([\d.]+) p99 ([\d.]+) max ([\d.]+) \| cpu avg ([\d.]+)', line)
    if m: rows.setdefault(m.group(1), []).append([float(x) for x in m.groups()[1:]])
print(f"{'':16s}{'load':>6s}{'wall avg':>22s}{'p10':>20s}{'p50':>20s}{'p99':>20s}{'cpu avg':>20s}")
for k, r in rows.items():
    def c(i): v = [x[i] for x in r]; return f"{st.median(v):7.1f} ({min(v):.1f}-{max(v):.1f})"
    print(f"{k:16s}{st.median([x[0] for x in r]):6.2f}{c(1):>22s}{c(2):>20s}{c(3):>20s}{c(5):>20s}{c(7):>20s}  [{len(r)} runs]")
E
