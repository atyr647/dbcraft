#!/usr/bin/env python3
"""How many slow ticks overlap a checkpoint, an autovacuum / autoanalyze run or a lock wait?   usage: attribution.py TAG [TAG...]
Sums slow_attribution over all trials of the given matrices (slow = slower than max(2 x the trial's median, 60 ms), see analyze.py)."""
import json, os, sys, collections
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
tot = collections.Counter(); slow = 0; ticks = 0; runs = 0
for tag in sys.argv[1:]:
    for line in open(os.path.join(base, f"matrix_{tag}.names")):
        label, name = line.split()
        p = os.path.join(base, name, "summary.json")
        if not os.path.exists(p): continue
        s = json.load(open(p)); runs += 1; slow += s["slow_ticks"]; ticks += s["ticks"]
        for k, v in s["slow_attribution"].items(): tot[k] += v
print(f"{runs} trials, {ticks} ticks, {slow} slow ticks; overlap with: " + ", ".join(f"{k} {v}" for k, v in tot.items()) + f"  (a tick can overlap several kinds; none = {tot['none']} = {100.0 * tot['none'] / max(slow, 1):.0f}%)")
