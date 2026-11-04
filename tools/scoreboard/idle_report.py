#!/usr/bin/env python3
"""Table of an idle_matrix.py result file: per (gateway, tick mode, players, before/after) the median over the repetitions with [min-max], for the tick time, CPU and chat round trip.
The chat columns are the median and range over the repetitions of each run's own p50 and p99 (a run has about one round trip per second, so its p99 rests on a few dozen samples)."""
import json, sys, collections

rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    tag = d.get("tag", "")
    if not tag.startswith("idle:") or "result" not in d:
        continue
    _, variant, gw, mode, n, rep = tag.split(":")
    rows[(gw, mode, int(n), variant)].append(d)


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


print("| gateway / tick | players | build | runs | tick mean ms | tick p99 ms | CPU cores | chat p50 ms | chat p99 ms | load before |")
print("|---|---|---|---|---|---|---|---|---|---|")
for key in sorted(rows):
    gw, mode, n, variant = key
    rs = rows[key]
    res = [d["result"] for d in rs]
    p50 = [r.get("rtt_p50") for r in res]
    p99 = [r.get("rtt_p99") for r in res]
    print("| %s / %s | %d | %s | %d | %s | %s | %s | %s | %s | %s |" % (
        gw, mode, n, variant, len(rs), cell([r.get("mspt_mean") for r in res]), cell([r.get("mspt_p99") for r in res], "%.1f"), cell([r.get("cpu_cores") for r in res], "%.3f"),
        cell(p50, "%.0f") if n else "-", cell(p99, "%.0f") if n else "-", cell([d["load_before"]["load1"] for d in rs], "%.1f")))
