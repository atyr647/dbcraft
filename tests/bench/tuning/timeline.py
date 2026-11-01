#!/usr/bin/env python3
"""Tick latency over time for one or more trials, in buckets of 10 s (200 ticks).   usage: timeline.py NAME [NAME...] [--bucket SECONDS]
Shows how a condition develops (e.g. an idle-in-transaction session pinning the vacuum horizon)."""
import csv, os, statistics, sys
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
args = [a for a in sys.argv[1:] if not a.startswith("--")]
bucket = 10
if "--bucket" in sys.argv: bucket = int(sys.argv[sys.argv.index("--bucket") + 1]); args = [a for a in args if a != str(bucket)]
for name in args:
    rows = list(csv.DictReader(open(os.path.join(base, name, "lat.csv"))))
    t0 = float(rows[0]["t_start"]); out = []
    cur, lo = [], 0
    for r in rows:
        b = int((float(r["t_start"]) - t0) // bucket)
        if b != lo and cur: out.append((lo * bucket, statistics.fmean(cur), max(cur))); cur = []
        lo = b; cur.append(float(r["lat_ms"]))
    if cur: out.append((lo * bucket, statistics.fmean(cur), max(cur)))
    print(f"{name}: " + "  ".join(f"{t}s:{a:.0f}/{m:.0f}" for t, a, m in out) + "   (avg/max ms per bucket)")
