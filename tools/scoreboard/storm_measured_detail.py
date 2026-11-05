#!/usr/bin/env python3
"""More columns per row of docs/perf-storm-measured-results.txt: tick distribution, online chat before / after the storm, gateway late ticks, join times."""
import json
for l in open("docs/perf-storm-measured-results.txt"):
    r = json.loads(l)
    x = r["result"]
    if "mspt_max" not in x:
        print("%-16s %4d vanilla: worst window p99 %.0f avg-of-p99 %.0f worst window avg %.0f; samples %s gc pauses %s max %s; before p50/p99 %s/%s after p50/p99 %s/%s; join p50/max to play %s/%s, all chunks p50/max %s/%s" % (
            r["tag"], r["n"], x["mspt_worst_window_p99"], x["mspt_p99"], x["mspt_worst_window_avg"], x["samples"], x.get("gc_pauses"), x.get("gc_pause_max_ms"),
            (x.get("online_before") or {}).get("p50"), (x.get("online_before") or {}).get("p99"), (x.get("online_after") or {}).get("p50"), (x.get("online_after") or {}).get("p99"),
            x.get("join_to_play_p50_s"), x.get("join_to_play_max_s"), x.get("join_all_chunks_p50_s"), x.get("join_all_chunks_max_s")))
        continue
    ob, od, oa = x.get("online_before") or {}, x.get("online_during") or {}, x.get("online_after") or {}
    print("%-16s %4d ticks %3d mean %5.1f p50 %5.1f p95 %5.1f p99 %5.1f max %5.1f >50 %3d >100 %2d | chat before p50/p99 %s/%s during n=%s p50/p95/p99/max %s/%s/%s/%s after p50/p99 %s/%s | late %s | join->play p50/max %.1f/%.1f s, all chunks p50/max %.1f/%.1f s | tickCPU %.1f ms/tick x %d = %.1f s; gw %.1f" % (
        r["tag"], r["n"], x["ticks"], x["mspt_mean"], x["mspt_p50"], x["mspt_p95"], x["mspt_p99"], x["mspt_max"], x["over50"], x["over100"],
        ob.get("p50"), ob.get("p99"), od.get("n"), od.get("p50"), od.get("p95"), od.get("p99"), od.get("max"), oa.get("p50"), oa.get("p99"), x.get("gateway_late_ticks"),
        x.get("join_to_play_p50_s", 0), x.get("join_to_play_max_s", 0), x.get("join_all_chunks_p50_s", 0), x.get("join_all_chunks_max_s", 0),
        x.get("tick_cpu_ms", 0), x["ticks"], x.get("tick_cpu_ms", 0) * x["ticks"] / 1000, x.get("gateway_cpu_ms", 0)))
