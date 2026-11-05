#!/usr/bin/env python3
"""Phases of the slowest ticks and the top functions of the profile rows (SCORE_STORM_PROF=1) of docs/perf-storm-measured-results.txt.
usage: storm_measured_profile.py [TAG_SUBSTRING] [TOP]"""
import json, sys
tag = sys.argv[1] if len(sys.argv) > 1 else "-rp"
top = int(sys.argv[2]) if len(sys.argv) > 2 else 28
for l in open("docs/perf-storm-measured-results.txt"):
    r = json.loads(l)
    if tag not in r["tag"]:
        continue
    x = r["result"]
    print("=====", r["tag"], "n", r["n"], "ticks", x.get("ticks"), "load", r["load_before"]["load1"], "worst", x.get("mspt_max"), "p99", round(x.get("mspt_p99", 0)), "over100", x.get("over100"))
    print("phase means (ms/tick):", {k[6:-5]: round(v, 1) for k, v in x.items() if k.startswith("phase_")})
    print("   tick players  total   proc   game    blk    chk  drain  moves   misc   chat    vis keepal   time   surv    fin   fout")
    for s in x.get("slowest_phases", []):
        print(" ".join("%6.0f" % s[0:1][0] if i == 0 else ("%6d" % v if i == 1 else "%6.1f" % v) for i, v in enumerate(s)))
    print("top functions: calls, total ms, self ms")
    for f in x.get("prof_functions", [])[:top]:
        print("  %-52s %8s %9s %9s" % tuple(f))
