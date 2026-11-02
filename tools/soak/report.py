#!/usr/bin/env python3
"""Tabulate a soak sample file (tools/soak/soak.py --out): table sizes over time, tick phases, gateway loop, snapshot age, waits.
usage: tools/soak/report.py /tmp/soak-samples.jsonl [number of tables to show]"""
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1])]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 8
names = set()
for r in rows:
    names |= set(r["tbl"])
big = lambda n: max(r["tbl"].get(n, {"bytes": 0})["bytes"] for r in rows)
names = sorted(names, key=lambda n: -big(n))[:top]
print("table sizes (MB) over time")
print("%6s " % "t(s)" + " ".join("%12s" % n.split(".")[-1][:12] for n in names))
for r in rows:
    print("%6.0f " % r["t"] + " ".join("%12.1f" % (r["tbl"].get(n, {"bytes": 0})["bytes"] / 1e6) for n in names))
print()
print("%6s %5s %7s %7s %7s %7s %7s %7s %9s %6s %8s %8s" % ("t(s)", "play", "tick/s", "sqltick", "process", "game", "chunks", "drain", "gw loop", "late", "rssMiB", "WALMB/m"))
for r in rows:
    ph, gc, gs = r.get("phases", {}), r.get("gwctl", {}), r.get("gwstats", {})
    print("%6.0f %5s %7s %7.1f %7.1f %7.1f %7.1f %7.1f %9s %6s %8.1f %8s" % (
        r["t"], r.get("play", "-"), r.get("ticks_per_s", "-"), ph.get("total", 0), ph.get("process", 0), ph.get("game", 0), ph.get("chunks", 0), ph.get("drain", 0),
        gc.get("last_ms", gs.get("avg_ms", "-")), gc.get("late", gs.get("late", "-")), r.get("gw_rss_mib", 0), r.get("wal_mb_per_min", "-")))
print()
last = rows[-1]
print("last sample: activity", last.get("act"), "oldest snapshots", last.get("xmin", [])[:2], "waits", last.get("wait"), "relations", last.get("rel"), "checkpoints", last.get("ckpt"))
print("dead tuples reported (last sample):", sorted(((v["dead"], t) for t, v in last["tbl"].items()), reverse=True)[:5])
