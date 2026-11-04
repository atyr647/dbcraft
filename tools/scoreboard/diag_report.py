#!/usr/bin/env python3
"""Diagnosis table: dbcraft with dynamics on (the campaign's cells) against dbcraft with dbcraft.dynamics = off (tools/scoreboard/diag.sh).   usage: diag_report.py RESULTS.jsonl"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from final_report import rng, load, group

rows = load(sys.argv[1])
print("| cell | metric | dynamics on (campaign) | dynamics off | reps on/off |")
print("|---|---|---|---|---|")
for (scen, n, mv, tag_on), label in [(("pop", 50, 0.0, "idle"), "idle, 50 players"), (("pop", 200, 0.0, "idle"), "idle, 200 players"), (("pop", 200, 1.0, "walk"), "200 players all walking")]:
    on = group(rows, (scen, n, mv, tag_on))["dbcraft"]
    off = group(rows, (scen, n, mv, "diag-nodyn"))["dbcraft"]
    for name, key in [("tick mean (ms)", "mspt_mean"), ("tick p99 (ms)", "mspt_p99"), ("CPU (cores)", "cpu_cores"), ("chat p50 (ms)", "rtt_p50")]:
        a = [r["result"][key] for r in on if key in r.get("result", {})]
        b = [r["result"][key] for r in off if key in r.get("result", {})]
        if a and b:
            print("| %s | %s | %s | %s | %d/%d |" % (label, name, rng(a), rng(b), len(a), len(b)))
on = group(rows, ("edit", 1, 0.0, "edit"))["dbcraft"]
off = group(rows, ("edit", 1, 0.0, "diag-nodyn"))["dbcraft"]
for name, key in [("single edit statement p50 (ms)", "single_stats.p50_ms"), ("single edit tick cost (ms)", "single_tick_stats.mean_ms"), ("fill 1,000 tick cost (ms)", "fill1k_tick_stats.p50_ms"),
                  ("fill 100,000 statement p50 (ms)", "fill100k_stats.p50_ms"), ("fill 100,000 tick cost (ms)", "fill100k_tick_stats.p50_ms")]:
    from final_report import get
    a = [get(r["result"], key) for r in on if r.get("result")]
    b = [get(r["result"], key) for r in off if r.get("result")]
    if a and b:
        print("| edits, one viewer | %s | %s | %s | %d/%d |" % (name, rng(a), rng(b), len(a), len(b)))
