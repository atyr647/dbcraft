#!/usr/bin/env python3
"""Failures of the pop runs: usage fails.py FILE [TAG]  -- clients dropped, why, and when (seconds into the run)"""
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    x = r.get("result", {})
    if r["scenario"] != "pop" or (len(sys.argv) > 2 and r.get("tag") != sys.argv[2]) or not x.get("failed"):
        continue
    ft = sorted(x.get("failure_times_s") or [])
    print(r["tag"], r["server"], r["n"], "rep", r["rep"], "failed", x["failed"], "of", x["clients"], x.get("failures"), x.get("disconnect_reasons"),
          "ready_clients", x.get("ready_clients"), "time_to_ready", round(x.get("time_to_ready_s", 0)), "first/median/last failure at", ft[:1], ft[len(ft) // 2:len(ft) // 2 + 1], ft[-1:])
