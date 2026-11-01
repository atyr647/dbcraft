#!/usr/bin/env python3
"""Queue-table growth and vacuum activity per label of a matrix.   usage: qsize.py TAG
Medians over the repetitions of: size of the four big queue tables at the end of the run (KB), their dead tuples, autovacuum runs on them, total autovacuum runs."""
import json, os, statistics, sys
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
tag = sys.argv[1]
Q = ["net.inbox", "net.outbox", "mc.play_in", "mc.play_out"]
groups, order = {}, []
for line in open(os.path.join(base, f"matrix_{tag}.names")):
    label, name = line.split()
    p = os.path.join(base, name, "summary.json")
    if not os.path.exists(p): continue
    if label not in groups: groups[label] = []; order.append(label)
    groups[label].append(json.load(open(p)))
print("| config | runs | queue tables size at end (KB, sum of net.inbox net.outbox mc.play_in mc.play_out) | dead tuples at end (sum) | autovacuum runs on them (sum) | autovacuum runs, all tables | avg tick ms | p99 | max |")
print("|---|---|---|---|---|---|---|---|---|")
for label in order:
    g = groups[label]
    size = statistics.median(sum(s["tables"][t]["size"] for t in Q if t in s["tables"]) / 1024 for s in g)
    dead = statistics.median(sum(s["tables"][t]["dead"] for t in Q if t in s["tables"]) for s in g)
    av = statistics.median(sum(s["tables"][t]["autovac"] for t in Q if t in s["tables"]) for s in g)
    avall = statistics.median(s.get("autovacuum_runs", 0) for s in g)
    print(f"| {label} | {len(g)} | {size:.0f} | {dead:.0f} | {av:.0f} | {avall:.0f} | {statistics.median(s['lat_avg'] for s in g):.1f} | {statistics.median(s['lat_p99'] for s in g):.1f} | {statistics.median(s['lat_max'] for s in g):.0f} |")
