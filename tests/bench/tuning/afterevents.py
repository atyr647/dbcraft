#!/usr/bin/env python3
"""Are ticks slow right AFTER an autovacuum / autoanalyze run finishes?   usage: afterevents.py TAG [TAG...] [--window 1.0]
ANALYZE updates a table's statistics, which invalidates the cached plans of every statement that uses the table: the next execution of each is re-planned.  That cost lands on the tick after the event,
not during it.  For every trial of the matrices: the share of slow ticks (slower than max(2 x median, 60 ms)) among the ticks that start within WINDOW seconds after an event ended,
against the share among all other ticks."""
import csv, datetime, json, os, re, sys
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
window = float(sys.argv[sys.argv.index("--window") + 1]) if "--window" in sys.argv else 1.0
tags = [a for a in sys.argv[1:] if not a.startswith("--") and a != str(window)]
def ts(s):
    m = re.match(r"(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\.(\d{3})", s)
    return datetime.datetime.strptime(m.group(1) + " " + m.group(2), "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp() + int(m.group(3)) / 1000 if m else None
tot = {"vac": [0, 0], "ana": [0, 0], "none": [0, 0]}      # [ticks, slow ticks]
for tag in tags:
    for line in open(os.path.join(base, f"matrix_{tag}.names")):
        label, name = line.split()
        if label.endswith('_stall'): continue          # the stalled-session trials are slow for another reason (pinned horizon)
        d = os.path.join(base, name)
        if not os.path.exists(os.path.join(d, "lat.csv")): continue
        rows = list(csv.DictReader(open(os.path.join(d, "lat.csv"))))
        lat = sorted(float(r["lat_ms"]) for r in rows); med = lat[len(lat) // 2]; thr = max(2 * med, 60.0)
        ev = []
        for l in open(os.path.join(d, "pg.log"), errors="replace"):
            t = ts(l)
            if t and ("automatic vacuum of table" in l or "automatic analyze of table" in l):
                ev.append(("vac" if "vacuum" in l else "ana", t))
        for r in rows:
            t0 = float(r["t_start"]); slow = float(r["lat_ms"]) > thr
            kind = "none"
            for k, te in ev:
                if 0 <= t0 - te <= window: kind = k if kind == "none" or k == "ana" else kind; break
            tot[kind][0] += 1; tot[kind][1] += slow
for k, (n, s) in tot.items():
    print(f"ticks starting within {window:g}s after an autovacuum/autoanalyze run ended ({k}): {n} ticks, {s} slow = {100.0 * s / max(n, 1):.1f}%" if k != "none" else f"all other ticks: {n} ticks, {s} slow = {100.0 * s / max(n, 1):.1f}%")
