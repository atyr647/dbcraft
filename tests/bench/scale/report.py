#!/usr/bin/env python3
"""Print the tables of docs/PERF-SCALE.md from tests/bench/scale/results/*.json.   usage: tests/bench/scale/report.py [flat|dense]
For every operation: p50 and p99 (cold and warm) per world size, the ratio between the largest and smallest world, and a fitted growth exponent b of
p50 ~ a * N^b (least squares on log-log; b near 0 is constant, b = 1 is linear; log N over a 200x range corresponds to b of about 0.1, so b <= 0.15 reads as O(1)/O(log n)).
"""
import json, math, os, sys

here = os.path.dirname(os.path.abspath(__file__))
series = sys.argv[1] if len(sys.argv) > 1 else "flat"
res = json.load(open(os.path.join(here, "results", f"{series}.json")))
sizes = sorted(int(k) for k in res)
ops = list(res[str(sizes[0])].get("ops", {}))


def fit(xs, ys):
    lx, ly = [math.log(x) for x in xs], [math.log(y) for y in ys]
    n = len(xs); mx, my = sum(lx) / n, sum(ly) / n
    sxx = sum((a - mx) ** 2 for a in lx); sxy = sum((a - mx) * (b - my) for a, b in zip(lx, ly))
    b = sxy / sxx if sxx else 0.0
    ss_tot = sum((v - my) ** 2 for v in ly); ss_res = sum((v - (my + b * (u - mx))) ** 2 for u, v in zip(lx, ly))
    return b, (1 - ss_res / ss_tot) if ss_tot else 1.0


print(f"## {series}: chunks per world size: " + ", ".join(f"{res[str(s)]['chunks']:,}" for s in sizes))
for phase in ("warm", "cold"):
    print(f"\n### {series}, {phase}: p50 (p99) in microseconds\n")
    print("| operation | " + " | ".join(f"{res[str(s)]['chunks']:,}" for s in sizes) + " | last/first (p50) | fitted b (R2) |")
    print("|---|" + "---|" * (len(sizes) + 2))
    for op in ops:
        p50 = [res[str(s)]["ops"][op][phase]["p50_us"] for s in sizes]
        p99 = [res[str(s)]["ops"][op][phase]["p99_us"] for s in sizes]
        b, r2 = fit([res[str(s)]["chunks"] for s in sizes], p50)
        print(f"| {op} | " + " | ".join(f"{a:,.0f} ({c:,.0f})" for a, c in zip(p50, p99)) + f" | {p50[-1] / p50[0]:.2f}x | {b:+.2f} ({r2:.2f}) |")
print(f"\n### {series}: storage per chunk (heap + toast + indexes, bytes per chunk)\n")
print("| table | " + " | ".join(f"{res[str(s)]['chunks']:,}" for s in sizes) + " |")
print("|---|" + "---|" * len(sizes))
for t in ("chunk", "chunk_section", "chunk_light", "chunk_cache"):
    row = []
    for s in sizes:
        r = res[str(s)]; n = r["chunks"]; rows, heap, toast, idx = r["sizes"][t]
        row.append(f"{(heap + toast + idx) / n:,.0f} (idx {idx / n:,.0f})")
    print(f"| {t} | " + " | ".join(row) + " |")
tot = []
for s in sizes:
    r = res[str(s)]; n = r["chunks"]
    tot.append(sum(v[1] + v[2] + v[3] for k, v in r["sizes"].items() if k.startswith("chunk")) / n)
print("| **all four** | " + " | ".join(f"**{t:,.0f}**" for t in tot) + " |")
print(f"\n### {series}: growth (generation), vacuum, plans\n")
print("| chunks | made | seconds | chunks/s | WAL bytes/chunk | checkpoints (timed/requested) | vacuum analyze s | DB MB | plans with a seq scan |")
print("|---|---|---|---|---|---|---|---|---|")
for s in sizes:
    r = res[str(s)]; g = r["growth"]
    seq = [k for k, p in r["plans"].items() if p["seq_scan"]]
    print(f"| {r['chunks']:,} | {g['chunks_made']:,} | {g['seconds']} | {g['chunks_per_s']} | {g['wal_bytes_per_chunk']} | {g['checkpoints_timed']}/{g['checkpoints_requested']} | {r['vacuum_analyze_s']} | {r['db_mb']} | {', '.join(seq) if seq else 'none'} |")
print("\nload average before the operations: " + ", ".join(f"{res[str(s)].get('load_before_ops')}" for s in sizes))
print("dead tuples / autovacuum runs / autoanalyze runs at measurement time (largest world): " + res[str(sizes[-1])]["dead_tuples"])
