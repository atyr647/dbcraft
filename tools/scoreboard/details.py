#!/usr/bin/env python3
"""Print the supporting detail behind the scoreboard table: block-edit responses and failure counts, set_blocks timing, the 10-minute tail (warm-up, GC pauses,
over-budget ticks) and the chunk-loading times.  usage: details.py [results.jsonl]"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(C.OUT, "results.jsonl")
for line in open(path):
    r = json.loads(line)
    x = r.get("result", {})
    if r.get("tag") == "misc2" and r["scenario"] == "blocks" and r["rep"] == 0:
        print(r["server"], "failed commands:", x.get("failed_commands"), "responses:", {k: (v or "")[:60] for k, v in (x.get("responses") or {}).items()},
              "| gamerule:", (x.get("gamerule_response") or "")[:70])
        print("   single", {k: round(v, 2) for k, v in x["single_edit"].items()}, "| fill1k", {k: round(v, 2) for k, v in x["fill_1k"].items()},
              "| fill100k", {k: round(v, 1) for k, v in x["fill_100k"].items()})
        if "set_blocks_1000_scattered_ms" in x:
            print("   set_blocks, 1000 scattered edits in one call (ms):", x["set_blocks_1000_scattered_ms"])
    if r.get("tag") == "tail" and x:
        s = x.get("series_avg_ms") or []
        t = max(1, len(s) // 3)
        print(r["server"], "tail: %d windows; mean tick first third %.1f ms, last third %.1f ms" % (len(s), sum(s[:t]) / t, sum(s[-t:]) / t),
              "| gc pauses", x.get("gc_pauses"), "max", x.get("gc_pause_max_ms"), "p99", x.get("gc_pause_p99_ms"),
              "| dbcraft: over50", x.get("over50"), "over100", x.get("over100"), "p99.9", x.get("mspt_p999"), "max", x.get("mspt_max"), "tps", x.get("tps"),
              "| failures", x.get("failures"), "failed clients", x.get("failed"), "| busy", round(r.get("machine_busy_frac", 0), 2), "load", r["load_before"]["load1"])
    if r["scenario"] == "chunkload" and r.get("tag") == "misc" and x:
        print(r["server"], "chunkload rep", r["rep"], {k: {"to_last_chunk_s": [round(t, 2) for t in v.get("to_last_chunk_s", [])], "chunks": v.get("chunks"), "mib": round(v.get("mib", 0), 1)}
                                                      for k, v in x.items() if isinstance(v, dict)})
