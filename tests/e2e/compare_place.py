#!/usr/bin/env python3
"""Compare the placement states dbcraft produced with what the REAL vanilla 26.3 server produced (tests/e2e/place_probe.py).

usage: tests/e2e/compare_place.py VANILLA.json OURS.json [--show N] [--family F[,F]]
A case is identical when both servers sent the same set of {position: block state} changes after the click (the placed block, the clicked block, and every neighbour
that changed: stairs corners, fence connections, a chest's partner).  Prints, per family, the cases identical and the first failures with the states' names.
Exit code 0 when every case of the selected families is identical.
"""
import json, os, sys
args = [x for x in sys.argv[1:] if not x.startswith("--")]
show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 6
fams = sys.argv[sys.argv.index("--family") + 1].split(",") if "--family" in sys.argv else None
if "--show" in sys.argv: args.remove(str(show))
if fams: args.remove(sys.argv[sys.argv.index("--family") + 1])
v = json.load(open(args[0])); o = json.load(open(args[1]))
names = {}
reports = os.path.join(os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")), "blocks.json")
for b, d in json.load(open(reports)).items():
    for s in d["states"]:
        p = s.get("properties") or {}
        names[s["id"]] = b + ("[" + ",".join("%s=%s" % kv for kv in sorted(p.items())) + "]" if p else "")
def nm(i): return names.get(i, "?%s" % i)
byfam = {}
def norm(r):
    # recordings made before the section position decode was fixed carry y + 2^24 for negative section y; updates outside the test box are random ticks of the world
    out = {}
    for k, s in r["updates"].items():
        x, y, z = (int(t) for t in k.split(","))
        if y > 8000000: y -= 16777216
        if 7 <= x <= 15 and -63 <= y <= -52 and 6 <= z <= 14: out["%d,%d,%d" % (x, y, z)] = s
    r["updates"] = out
vd = {r["desc"] + "|" + str(r["i"]): r for r in v}
vd = {}
for r in v: vd.setdefault(r["desc"], []).append(r)
seen = {}
pairs = []
for b in o:                                   # a recording of a subset (--only) is matched by the case's description
    k = seen.get(b["desc"], 0); seen[b["desc"]] = k + 1
    pairs.append((vd[b["desc"]][k], b))
for a, b in pairs:
    norm(a); norm(b)
    if fams and a["family"] not in fams: continue
    byfam.setdefault(a["family"], []).append((a, b))
bad = 0
for fam, cs in byfam.items():
    ok = [c for c in cs if c[0]["updates"] == c[1]["updates"]]
    print("%-12s %3d of %3d identical" % (fam, len(ok), len(cs)))
    shown = 0
    for a, b in cs:
        if a["updates"] == b["updates"]: continue
        bad += 1
        if shown < show:
            shown += 1
            print("   DIFFERS: %s (yaw %s pitch %s cursor %s)" % (a["desc"], a["yaw"], a["pitch"], a["cursor"]))
            for k in sorted(set(a["updates"]) | set(b["updates"])):
                x, y = a["updates"].get(k), b["updates"].get(k)
                if x != y: print("      %-12s vanilla %-70s dbcraft %s" % (k, nm(x) if x is not None else "-", nm(y) if y is not None else "-"))
print("%d cases differ" % bad)
sys.exit(1 if bad else 0)
