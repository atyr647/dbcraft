#!/usr/bin/env python3
"""Summarise tests/bench/joinbudget/curve.sh output: one row per configuration label, the median over the repetitions (and the min-max of the worst tick).
usage: summarize.py /tmp/jb-curve.jsonl [--md]"""
import json, statistics, sys
from collections import OrderedDict

rows = OrderedDict()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    r = json.loads(line)
    rows.setdefault(r["label"], []).append(r)

def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 1) if xs else None

md = "--md" in sys.argv
hdr = ["config", "runs", "worst tick wall ms (min-max)", "worst tick CPU ms", "tick p99 wall ms", "ticks >100 ms wall", "all in (s)", "queue p50 / max (s)", "timed out", "unfinished"]
if md:
    print("| " + " | ".join(hdr) + " |"); print("|" + "---|" * len(hdr))
else:
    print(" | ".join(hdr))
for label, rs in rows.items():
    worst = [r["ticks"]["wall_max"] for r in rs]
    cells = [label, str(len(rs)), f"{med(worst)} ({min(worst)}-{max(worst)})", str(med([r["ticks"]["cpu_max"] for r in rs])), str(med([r["ticks"]["wall_p99"] for r in rs])),
             str(med([r["ticks"]["over100"] for r in rs])), str(med([r["clients"]["all_in_s"] for r in rs])),
             f"{med([r['clients']['queue_p50_s'] for r in rs])} / {med([r['clients']['queue_max_s'] for r in rs])}",
             str(max(r["clients"]["timed_out"] for r in rs)), str(max(r["clients"]["unfinished"] for r in rs))]
    print(("| " + " | ".join(cells) + " |") if md else " | ".join(cells))
