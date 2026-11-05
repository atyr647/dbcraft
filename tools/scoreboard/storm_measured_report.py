#!/usr/bin/env python3
"""One line per row of docs/perf-storm-measured-results.txt (docs/PERF-STORM-MEASURED.md)."""
import json, sys
path = sys.argv[1] if len(sys.argv) > 1 else "docs/perf-storm-measured-results.txt"
print("%-20s %4s %5s %6s %6s %5s %5s | chat during p50/p99/max   | %7s %7s | %5s %5s | tickCPU ms/tick total_s | gwCPU | busy" % ("tag", "n", "load", "worst", "p99", ">100", ">50", "ready_s", "storm_s", "fail", "onfl"))
for l in open(path):
    r = json.loads(l)
    x = r.get("result", {})
    od = x.get("online_during") or {}
    nt = x.get("ticks", 0)
    tc = x.get("tick_cpu_ms")
    print("%-20s %4d %5.1f %6s %6s %5s %5s | %6s %6s %6s | %7s %7s | %5s %5s | %s %s | %s | %.2f" % (
        r["tag"], r["n"], r["load_before"]["load1"],
        "%.0f" % x["mspt_max"] if "mspt_max" in x else ("%.0f" % x["mspt_worst_window_p99"] if "mspt_worst_window_p99" in x else "-"),
        "%.0f" % x["mspt_p99"] if "mspt_p99" in x else "-", x.get("over100", "-"), x.get("over50", "-"),
        "%.0f" % od["p50"] if od else "-", "%.0f" % od["p99"] if od else "-", "%.0f" % od["max"] if od else "-",
        "%.1f" % x["time_to_ready_s"] if "time_to_ready_s" in x else "-", "%.1f" % x["storm_total_s"] if "storm_total_s" in x else "-",
        x.get("failed", "-"), x.get("online_failed", "-"),
        "%.1f" % tc if tc else "-", "%.1f" % (tc * nt / 1000) if tc else "-", "%.1f" % x["gateway_cpu_ms"] if "gateway_cpu_ms" in x else "-",
        r.get("machine_busy_frac", -1)) + ("  ERROR " + r["error"] if "error" in r else ""))
