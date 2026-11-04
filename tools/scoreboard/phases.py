#!/usr/bin/env python3
"""Per-phase breakdown of the dbcraft pop runs in a results file: usage phases.py FILE [TAG]"""
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["scenario"] != "pop" or "dbcraft" not in r["server"] or (len(sys.argv) > 2 and r.get("tag") != sys.argv[2]):
        continue
    x = r["result"]
    print(r["tag"], r["n"], r["moving"], "rep", r["rep"], {k: round(v, 2) for k, v in x.items() if k.startswith("phase") or k in ("mspt_mean", "mspt_p50", "mspt_p99", "cpu_cores", "gateway_late_ticks", "tps")})
    print("  by residue (mean,max):", x["by_residue"])
    print("  slowest (tick,total,process,game,blocks,chunks,drain,t%20,t%300):", x["slowest"][:5])
