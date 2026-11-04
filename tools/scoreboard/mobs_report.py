#!/usr/bin/env python3
"""Mobs rows of the final campaign from tools/scoreboard/mobs.sh output.   usage: mobs_report.py OUTDIR [LABEL=final]
vanilla: CPU of the 'Server thread' per tick = cores x max(mean tick, 50 ms) (docs/PERF-MOBS2.md), and the `tick query` mean / p99 (wall; the machine was quiet, so it is usable here);
dbcraft: on-CPU ms of the backend per entity tick (tests/bench/mobs2/bench.sql, inline mode: what mc.server_tick pays), mean of the 100 measured ticks, and p99.
Winner rule as everywhere: ranges of the repetitions overlap = TIE."""
import collections, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from final_report import fmt, rng, verdict

d = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else "final"
van = collections.defaultdict(list)
for l in open(os.path.join(d, "vanilla.jsonl")):
    r = json.loads(l)
    van[r["scenario"]].append(r)
db = collections.defaultdict(list)
pat = re.compile(r"rep (\d+) \| (\S+?)/(\S+) mobs=(\d+) items=(\d+) where=(\S+) walk=(\S+) viewers=(\d+) \| cpu ms avg ([\d.]+) p50 ([\d.]+) p99 ([\d.]+) \| wall avg ([\d.]+) p99 ([\d.]+) \|.*load ([\d.]+)")
for l in open(os.path.join(d, "dbcraft.txt")):
    m = pat.search(l)
    if m:
        g = m.groups()
        db[(g[2], g[1])].append(dict(cpu=float(g[8]), p99=float(g[10]), wall=float(g[11]), load=float(g[13])))
NAMES = {"500v": "500 awake cows, viewer in range", "2000v": "2,000 awake cows, viewer in range", "5000v": "5,000 awake cows, viewer in range",
         "500n": "500 awake cows, nobody in range", "2000n": "2,000 awake cows, nobody in range", "5000n": "5,000 awake cows, nobody in range", "5000i": "5,000 resting items, viewer in range"}
print("| scenario | vanilla server-thread CPU ms/tick | vanilla tick mean / p99 (wall, ms) | dbcraft entity tick CPU ms | dbcraft p99 / wall mean | ratio d/v | winner | reps v/d | load v / d |")
print("|---|---|---|---|---|---|---|---|---|")
rows = []
for code in ["500v", "2000v", "5000v", "500n", "2000n", "5000n", "5000i"]:
    vs, ds = van.get(code, []), db.get((code, label), [])
    if not vs and not ds:
        continue
    vcpu = [r["server_thread_cores"] * max(r["mean_ms"], 50.0) for r in vs]
    dcpu = [r["cpu"] for r in ds]
    w, f = verdict(vcpu, dcpu)
    vl = [float(r["load"]) for r in vs]
    dl = [r["load"] for r in ds]
    print("| %s | %s | %s / %s | %s | %s / %s | %s | %s | %d/%d | %s / %s |" % (
        NAMES[code], rng(vcpu) if vcpu else "not run", fmt(C.percentile([r["mean_ms"] for r in vs], 50)) if vs else "-", fmt(C.percentile([r["p99_ms"] for r in vs], 50)) if vs else "-",
        rng(dcpu) if dcpu else "not run", fmt(C.percentile([r["p99"] for r in ds], 50)) if ds else "-", fmt(C.percentile([r["wall"] for r in ds], 50)) if ds else "-",
        ("%.2f" % (C.percentile(dcpu, 50) / C.percentile(vcpu, 50))) if vcpu and dcpu else "", w + ((" (" + f + ")") if f else ""), len(vcpu), len(dcpu),
        "%.1f-%.1f" % (min(vl), max(vl)) if vl else "-", "%.1f-%.1f" % (min(dl), max(dl)) if dl else "-"))
    rows.append({"scenario": NAMES[code], "vanilla": rng(vcpu) if vcpu else "", "dbcraft": rng(dcpu) if dcpu else "", "winner": w, "by": f})
for code in ["2000v", "5000v"]:
    ds = db.get((code, label + "-walk1"), [])
    if ds:
        print("| %s, every mob walking all the time (dbcraft only) | - | - | %s | - | - | - | 0/%d | - |" % (NAMES[code], rng([r["cpu"] for r in ds]), len(ds)))
if "--rows" in sys.argv:
    json.dump(rows, open(sys.argv[sys.argv.index("--rows") + 1], "w"), indent=1)
