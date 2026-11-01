#!/usr/bin/env python3
"""Print the details of one analysed trial: slowest ticks, busiest tables, server events.   usage: show.py NAME [NAME...]"""
import json, sys, os
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
for name in sys.argv[1:]:
    S = json.load(open(os.path.join(base, name, "summary.json")))
    print(f"=== {name}  confs={S['confs']!r} N={S['players']} frac={S['frac']} ticks={S['ticks']}")
    print("phases avg ms:", {k: round(v, 1) for k, v in S["phase_avg"].items()}, "gen", round(S["gen_avg"], 1), "drain", round(S["drain_avg"], 1), "commit", round(S["commit_avg"], 2))
    print("slowest ticks:")
    for s in S["slowest"][:8]:
        print("  ", s)
    if "tables" in S:
        print("tables by updates:")
        for t, v in sorted(S["tables"].items(), key=lambda kv: -(kv[1]["upd"] + kv[1]["ins"]))[:12]:
            hp = "-" if v["hot_pct"] is None else f"{v['hot_pct']:.0f}%"
            print(f"   {t:28s} ins {v['ins']:8d} upd {v['upd']:8d} del {v['del']:8d} hot {hp:>5s} dead {v['dead']:8d} autovac {v['autovac']} size {v['size']/1024:.0f} KB (+{v['size_growth']/1024:.0f})")
    print("events:", S["events"])
    for ev in S["events_list"][:15]:
        print("  ", ev)
    if S.get("indexes_unused_in_run"):
        print("indexes never scanned in the run (largest first):", [(i, sz) for i, sz, t in S["indexes_unused_in_run"][:8]])
