#!/usr/bin/env python3
"""Summary of docs/perf-pairing-results.txt (docs/PERF-PAIRING.md): one line per cell; with --prof TAG the phases of the slowest ticks and the top functions.
usage: pairing_report.py [--file PATH] [--prof TAG] [--top N]"""
import json, sys, argparse
ap = argparse.ArgumentParser()
ap.add_argument("--file", default="docs/perf-pairing-results.txt")
ap.add_argument("--prof")
ap.add_argument("--top", type=int, default=40)
a = ap.parse_args()
rows = [json.loads(l) for l in open(a.file)]
if a.prof:
    for r in rows:
        if a.prof in r["tag"]:
            x = r["result"]
            print("=====", r["tag"], "worst", x.get("mspt_max"), "over100", x.get("over100"), "over50", x.get("over50"))
            print("phase means:", {k[6:-5]: round(v, 1) for k, v in x.items() if k.startswith("phase_")})
            for s in x.get("slowest_phases", [])[:8]:
                print("  ", [round(v, 1) for v in s])
            for f in x.get("prof_functions", [])[:a.top]:
                print("  %-52s %8s %9s %9s" % tuple(f))
    sys.exit()
print("%-16s %4s %5s %6s %6s %6s %5s %5s | chat p50/p99/max | ready_s | tick_cpu_ms/tick | mean_mspt" % ("tag", "n", "load", "worst", "p99", "p95", ">100", ">50"))
for r in rows:
    x = r.get("result", {})
    od = x.get("online_during") or {}
    print("%-16s %4d %5.1f %6.1f %6.1f %6.1f %5s %5s | %5s %5s %5s | %6s | %6s | %s" % (
        r["tag"], r["n"], r["load_before"]["load1"], x.get("mspt_max", 0), x.get("mspt_p99", 0), x.get("mspt_p95", 0),
        x.get("over100", "-"), x.get("over50", "-"),
        "%.0f" % od["p50"] if od else "-", "%.0f" % od["p99"] if od else "-", "%.0f" % od["max"] if od else "-",
        "%.1f" % x["time_to_ready_s"] if "time_to_ready_s" in x else "-", "%.1f" % x["tick_cpu_ms"] if x.get("tick_cpu_ms") else "-",
        "%.1f" % x.get("mspt_mean", 0)) + ("  ERROR " + r["error"] if "error" in r else ""))
