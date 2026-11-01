#!/usr/bin/env python3
"""The costliest plan nodes of one statement in an auto_explain log.   usage: log_plan.py LOGFILE 'text the Query Text starts with' [N]"""
import re, sys
t = open(sys.argv[1]).read()
key = sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 14
best = None
for e in re.split(r"\n(?=\d{4}-\d\d-\d\d )", t):
    m = re.search(r"duration: ([\d.]+) ms", e)
    if m and ("Query Text: " + key) in e:
        d = float(m.group(1))
        if best is None or d > best[0]:
            best = (d, e)
if best is None:
    sys.exit("no such statement")
rows = []
for l in best[1].split("\n"):
    m = re.search(r"actual time=([\d.]+)\.\.([\d.]+) rows=(\d+) loops=(\d+)", l)
    if m:
        rows.append((float(m.group(2)) * int(m.group(4)), m.group(3), m.group(4), l.strip().split("(cost")[0][:70]))
print("statement %.1f ms" % best[0])
for r in sorted(rows, reverse=True)[:n]:
    print("%8.1f ms rows=%-7s loops=%-7s %s" % r)
