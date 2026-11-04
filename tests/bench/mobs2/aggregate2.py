#!/usr/bin/env python3
"""Tables of docs/PERF-MOBS2.md part 2 from the files of tests/bench/mobs2/campaign2.sh.   usage: aggregate2.py RESULT_DIR
vanilla: Server-thread CPU per tick = cores x max(mean tick, 50 ms); dbcraft: CPU ms per entity tick (on-CPU time of the backend, mean over 100 ticks) and p50.  median [min-max] over the repetitions."""
import json, re, statistics as st, sys, os, collections

d = sys.argv[1]
van = collections.defaultdict(list)
for l in open(os.path.join(d, "vanilla.jsonl")):
    r = json.loads(l)
    van[r["scenario"]].append(dict(cpu=r["server_thread_cores"] * max(r["mean_ms"], 50.0), mean=r["mean_ms"], load=float(r["load"])))
db = collections.defaultdict(list)
pat = re.compile(r"rep (\d+) \| (\S+?)/(\S+) mobs=(\d+) items=(\d+) where=(\S+) walk=(\S+) viewers=(\d+) \| cpu ms avg ([\d.]+) p50 ([\d.]+) p99 ([\d.]+) \| wall avg ([\d.]+) p99 ([\d.]+) \| ai ([\d.]+) phys ([\d.]+) trk ([\d.]+) pick ([\d.]+) \| awake (\d+) lanes (\d+) \| out rows (\d+) KB (\d+) \| wal KB (\d+) \| load ([\d.]+)")
for l in open(os.path.join(d, "dbcraft.txt")):
    m = pat.search(l)
    if m:
        g = m.groups()
        db[(g[2], g[1])].append(dict(cpu=float(g[8]), p50=float(g[9]), awake=int(g[17]), kb=int(g[20]), wal=int(g[21]), load=float(g[22])))


def rng(xs, f="%.1f"):
    return (f + " [" + f + "-" + f + "]") % (st.median(xs), min(xs), max(xs)) if xs else "-"


print("| scenario | vanilla CPU ms/tick | old (part 1) | new | new, nobody connected | new, every mob walks | new / vanilla | old / vanilla |")
print("|---|---|---|---|---|---|---|---|")
for code in ["500n", "2000n", "5000n", "500v", "2000v", "5000v"]:
    v = van.get(code, [])
    if not v and not db.get((code, "new")): continue
    vm = st.median([x["cpu"] for x in v]) if v else float("nan")
    def cell(lbl):
        xs = [x["cpu"] for x in db.get((code, lbl), [])]
        return rng(xs)
    nm = st.median([x["cpu"] for x in db[(code, "new")]]) if db.get((code, "new")) else float("nan")
    om = st.median([x["cpu"] for x in db[(code, "old")]]) if db.get((code, "old")) else float("nan")
    print("| %s | %s | %s | %s | %s | %s | %.2f | %.2f |" % (code, rng([x["cpu"] for x in v]), cell("old"), cell("new"), cell("new-nobody"), cell("new-walk1"), nm / vm, om / vm))
print()
print("load during the vanilla runs: " + "; ".join("%s %s" % (c, rng([x["load"] for x in v], "%.1f")) for c, v in van.items()))
print("load during the dbcraft runs: " + "; ".join("%s/%s %s" % (c, l, rng([x["load"] for x in v], "%.1f")) for (c, l), v in sorted(db.items())))
print("p50 (ms): " + "; ".join("%s/%s %s" % (c, l, rng([x["p50"] for x in v])) for (c, l), v in sorted(db.items())))
print("awake mobs per tick outside lanes or stepping: " + "; ".join("%s/%s %d" % (c, l, st.median([x["awake"] for x in v])) for (c, l), v in sorted(db.items())))
