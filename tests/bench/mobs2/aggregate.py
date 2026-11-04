#!/usr/bin/env python3
"""Tables of docs/PERF-MOBS2.md from the files of the V/D alternation.   usage: aggregate.py RESULT_DIR   (vanilla.jsonl, dbcraft.txt, split.txt as written by tools/entity/vanilla_mobs.py + tests/bench/mobs2/after.sh)
Per scenario: median [min-max] over the repetitions.  vanilla: tick mean / p99 (`tick query`, mean of the samples of the window), CPU of the "Server thread" in ms per 50 ms tick, JVM cores;
dbcraft: CPU ms per entity tick (schedstat, on-CPU) mean and p99, wall ms, play_out KB per tick, WAL KB per tick."""
import json, re, statistics as st, sys, os, collections

d = sys.argv[1]
van = collections.defaultdict(list)
for l in open(os.path.join(d, "vanilla.jsonl")):
    r = json.loads(l); van[r["scenario"]].append(r)
db = collections.defaultdict(list)
pat = re.compile(r"rep (\d+) \| (\S+?)/(\S+) mobs=(\d+) items=(\d+) where=(\S+) walk=(\S+) viewers=(\d+) \| cpu ms avg ([\d.]+) p50 ([\d.]+) p99 ([\d.]+) \| wall avg ([\d.]+) p99 ([\d.]+) \| ai ([\d.]+) phys ([\d.]+) trk ([\d.]+) pick ([\d.]+) \| awake (\d+) lanes (\d+) \| out rows (\d+) KB (\d+) \| wal KB (\d+) \| load ([\d.]+)")
for l in open(os.path.join(d, "dbcraft.txt")):
    m = pat.search(l)
    if m:
        g = m.groups(); db[(g[2], g[1])].append(dict(rep=int(g[0]), cpu=float(g[8]), p50=float(g[9]), p99=float(g[10]), wall=float(g[11]), awake=int(g[17]), kb=int(g[20]), wal=int(g[21]), load=float(g[22])))
spl = collections.defaultdict(list)
if os.path.exists(os.path.join(d, "split.txt")):
    for l in open(os.path.join(d, "split.txt")):
        m = re.search(r"split new r(\d+)/(\S+) \| B: ticks run (\d+) of (\d+) \| ms wall avg ([\d.]+) p50 ([\d.]+) p99 ([\d.]+) max ([\d.]+).*?load ([\d.]+)", l)
        if m:
            spl[m.group(2)].append(dict(n=int(m.group(3)), avg=float(m.group(5)), p99=float(m.group(7)), load=float(m.group(9))))


def rng(xs, f="%.1f"):
    if not xs: return "-"
    return (f + " [" + f + "-" + f + "]") % (st.median(xs), min(xs), max(xs))


order = ["500v", "2000v", "5000v", "2000n", "5000n", "5000i"]
print("### vanilla 26.3 (real server), per scenario")
print("| scenario | reps | tick mean ms | tick p99 ms | server-thread CPU ms per tick (cores x max(mean, 50 ms)) | JVM cores | viewer KB/s | load |")
print("|---|---|---|---|---|---|---|---|")
for s in order:
    rs = van.get(s, [])
    if not rs: continue
    cpu = [r["server_thread_cores"] * max(r["mean_ms"], 50.0) for r in rs]        # CPU per tick = cores x time per tick (a tick that takes longer than 50 ms is the whole interval)
    print(f"| {s} | {len(rs)} | {rng([r['mean_ms'] for r in rs])} | {rng([r['p99_ms'] for r in rs], '%.0f')} | {rng(cpu)} | {rng([r['jvm_cores'] for r in rs], '%.2f')} | "
          f"{rng([r.get('viewer_bytes_per_s', 0) / 1000 for r in rs], '%.0f')} | {rng([float(r['load']) for r in rs], '%.0f')} |")
print()
print("### dbcraft entity tick (inline = what the server tick pays), CPU ms per tick")
print("| scenario | variant | reps | CPU mean | CPU p50 | CPU p99 | wall mean | out KB/tick | WAL KB/tick | load |")
print("|---|---|---|---|---|---|---|---|---|---|")
for s in order:
    for v in ["old", "new", "old-walk1", "new-walk1"]:
        rs = db.get((s, v), [])
        if not rs: continue
        print(f"| {s} | {v} | {len(rs)} | {rng([r['cpu'] for r in rs])} | {rng([r['p50'] for r in rs])} | {rng([r['p99'] for r in rs])} | {rng([r['wall'] for r in rs])} | {rng([r['kb'] for r in rs], '%.0f')} | {rng([r['wal'] for r in rs], '%.0f')} | {rng([r['load'] for r in rs], '%.0f')} |")
print()
print("### dbcraft split mode: the entity connection B (A stood in by a clock), wall ms per entity tick")
print("| scenario | reps | ticks run of 150 | B wall mean | B wall p99 |")
print("|---|---|---|---|---|")
for s in order:
    rs = spl.get(s, [])
    if rs: print(f"| {s} | {len(rs)} | {rng([r['n'] for r in rs], '%.0f')} | {rng([r['avg'] for r in rs])} | {rng([r['p99'] for r in rs])} |")
