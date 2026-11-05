#!/usr/bin/env python3
"""One line per run of docs/perf-storm-measured-paced.txt."""
import json
for l in open("docs/perf-storm-measured-paced.txt"):
    d = json.loads(l)
    t, c = d["ticks"], d["clients"]
    print("%-22s load %.1f | wall worst %6.1f p99 %6.1f avg %5.1f >50/>100 %3d/%3d | CPU worst %6.1f p99 %6.1f avg %5.1f >50/>100 %3d/%3d | done %d/%d | all in %s s | ticks %d | %d s" % (
        d["label"], d["load_at_start"], t["wall_max"], t["wall_p99"], t["wall_avg"], t["over50"], t["over100"], t["cpu_max"], t["cpu_p99"], t["cpu_avg"], t["cpu_over50"], t["cpu_over100"],
        c["done"], c["joiners"], c["all_in_s"], t["n"], d["seconds"]))
    x = d.get("x8")
    if x:
        print("    without the first 8 ticks: CPU worst %s p99 %s avg %s >100: %s | wall worst %s p99 %s | worst ticks (tick, cpu ms, in play) %s" % (
            x["cpu_max8"], x["cpu_p99_8"], x["cpu_avg8"], x["cpu_over100_8"], x["wall_max8"], x["wall_p99_8"], x["worst_ticks"]))
