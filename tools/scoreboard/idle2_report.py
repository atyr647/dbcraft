#!/usr/bin/env python3
"""Table of an idle2_matrix.py result file (docs/PERF-IDLE2.md): per (players, server) the median over the repetitions with [min-max] for tick time, CPU (cluster + gateway for dbcraft,
the JVM for vanilla), chat round trip and the load average before the run.  Tags are idle2:<server>:<n>:rep<k>, server = vanilla | before | after.

usage: idle2_report.py FILE [TAGPREFIX=idle2] [--by-extras]   (--by-extras: the chat round trips of --realistic runs split by whether the kinds ahead of the chat were all movement)
"""
import collections, json, sys

path = sys.argv[1]
prefix = (sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else "idle2") + ":"
rows = collections.defaultdict(list)
for line in open(path):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    tag = d.get("tag", "")
    if not tag.startswith(prefix):
        continue
    if "result" not in d:
        print("# no result: %s %s" % (tag, d.get("error", "")), file=sys.stderr)
        continue
    _, server, n, rep = tag.split(":")
    if int(n) and d["result"].get("failed", 0) > max(1, 0.02 * int(n)):
        print("# dropped (clients failed: %s of %s): %s" % (d["result"]["failed"], n, tag), file=sys.stderr)
        continue
    rows[(int(n), server)].append(d)


def med(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2


def cell(vals, fmt="%.2f"):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "-"
    return (fmt + " [" + fmt + "-" + fmt + "]") % (med(vals), min(vals), max(vals))


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


order = {"vanilla": 0, "before": 1, "after": 2}
print("| players | server | runs | tick mean ms | tick p99 ms | CPU cores | chat p50 ms | chat p99 ms | load before |")
print("|---|---|---|---|---|---|---|---|---|")
for (n, server) in sorted(rows, key=lambda k: (k[0], order.get(k[1], 9))):
    rs = rows[(n, server)]
    res = [d["result"] for d in rs]
    print("| %d | %s | %d | %s | %s | %s | %s | %s | %s |" % (
        n, server, len(rs), cell([r.get("mspt_mean") for r in res]), cell([r.get("mspt_p99") for r in res], "%.1f"), cell([r.get("cpu_cores") for r in res], "%.3f"),
        cell([r.get("rtt_p50") for r in res], "%.0f") if n else "-", cell([r.get("rtt_p99") for r in res], "%.0f") if n else "-", cell([d["load_before"]["load1"] for d in rs], "%.1f")))

if "--by-extras" in sys.argv:
    print()
    print("| players | server | chats | all-movement ahead p50 ms | other kinds ahead p50 ms | p99 all |")
    print("|---|---|---|---|---|---|")
    for (n, server) in sorted(rows, key=lambda k: (k[0], order.get(k[1], 9))):
        a, b, allr = [], [], []
        for d in rows[(n, server)]:
            for rtt, kinds in d["result"].get("rtt_detail", []):
                allr.append(rtt)
                (a if set(kinds) <= {"move_player_pos_rot"} else b).append(rtt)
        if allr:
            print("| %d | %s | %d (%d / %d) | %s | %s | %.0f |" % (n, server, len(allr), len(a), len(b), "%.0f" % pct(a, 50) if a else "-", "%.0f" % pct(b, 50) if b else "-", pct(allr, 99)))
