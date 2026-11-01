#!/usr/bin/env python3
"""List the slowest auto_explain entries of a DIAG=1 trial.   usage: slowlog.py NAME [MIN_MS=50] [TOP=8] [--plan]
Each entry: duration, the statement (first line) and, with --plan, the plan text."""
import os, re, sys
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
name = sys.argv[1]; min_ms = float(sys.argv[2]) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else 50.0
top = int(sys.argv[3]) if len(sys.argv) > 3 and not sys.argv[3].startswith("--") else 8
want_plan = "--plan" in sys.argv
text = open(os.path.join(base, name, "pg.log"), errors="replace").read()
entries = re.split(r"\n(?=\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} UTC \[\d+\] )", text)
found = []
for e in entries:
    m = re.search(r"LOG:  duration: ([\d.]+) ms  plan:\n(.*)", e, re.S)
    if not m: continue
    d = float(m.group(1))
    if d >= min_ms: found.append((d, e[:23], m.group(2)))
found.sort(reverse=True)
print(f"{len(found)} auto_explain entries >= {min_ms} ms")
for d, ts, body in found[:top]:
    lines = body.split("\n")
    first = lines[0].strip()[:200]
    print(f"--- {d:9.1f} ms  {ts}  {first}")
    if want_plan:
        print("\n".join(lines[1:45]))
