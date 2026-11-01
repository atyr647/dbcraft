#!/usr/bin/env python3
"""Aggregate a matrix (matrix.sh) into a markdown table of medians over the repetitions.   usage: table.py TAG [--sort] [--full]
Columns are medians of the per-trial statistic; 'spread' is (max - min) of the per-trial average latency, i.e. the noise to compare differences against."""
import json, os, statistics, sys
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
tag = sys.argv[1]
groups = {}
order = []
for line in open(os.path.join(base, f"matrix_{tag}.names")):
    label, name = line.split()
    p = os.path.join(base, name, "summary.json")
    if not os.path.exists(p): continue
    if label not in groups: groups[label] = []; order.append(label)
    groups[label].append(json.load(open(p)))
med = lambda xs: statistics.median(xs)
rows = []
for label in order:
    g = groups[label]
    rows.append((label, len(g), med([s["lat_avg"] for s in g]), med([s["lat_p50"] for s in g]), med([s["lat_p99"] for s in g]), med([s["lat_p999"] for s in g]),
                 med([s["lat_max"] for s in g]), med([s["over50"] for s in g]), med([s["over100"] for s in g]), med([s["commit_avg"] for s in g]),
                 med([s.get("wal_kb_per_tick", 0) for s in g]), max(s["lat_avg"] for s in g) - min(s["lat_avg"] for s in g),
                 med([s.get("temp_files", 0) for s in g]), med([s.get("buffers_backend", 0) for s in g])))
if "--sort" in sys.argv: rows.sort(key=lambda r: r[2])
print("| config | runs | avg ms | p50 | p99 | p99.9 | max | ticks >50 | ticks >100 | commit avg ms | WAL KB/tick | spread of avg | temp files | backend buffer writes |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    print(f"| {r[0]} | {r[1]} | {r[2]:.1f} | {r[3]:.1f} | {r[4]:.1f} | {r[5]:.0f} | {r[6]:.0f} | {r[7]:.0f} | {r[8]:.0f} | {r[9]:.2f} | {r[10]:.0f} | {r[11]:.1f} | {r[12]:.0f} | {r[13]:.0f} |")
