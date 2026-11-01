#!/usr/bin/env python3
"""Median / min..max of every workload and variant from bench_round.sh's raw file, plus the speedup against A (distro) and B (-O2 control).
usage: tools/pgbuild/analyze.py RAWFILE "A B C D"          Speedup = median(A) / median(variant): above 1 is faster than the distro build."""
import re, statistics as st, sys
raw, variants = sys.argv[1], sys.argv[2].split()
data = {}      # (workload, metric) -> variant -> [values]
loads = []
for line in open(raw):
    f = line.split()
    if len(f) < 4: continue
    rnd, v, wl = f[0], f[1], f[2]
    m = re.search(r'load=([\d.]+)', line)
    if m: loads.append(float(m.group(1)))
    if 'value=' in line:
        data.setdefault((wl, 'cpu'), {}).setdefault(v, []).append(float(re.search(r'value=([\d.]+)', line).group(1)))
        continue
    m = re.search(r'wall avg ([\d.]+) p10 [\d.]+ p50 [\d.]+ p95 [\d.]+ p99 ([\d.]+) max [\d.]+ \| cpu avg ([\d.]+) p10 [\d.]+ p50 ([\d.]+) p95 [\d.]+ p99 ([\d.]+)', line)
    if m:
        for name, val in (('cpu avg', m.group(3)), ('cpu p99', m.group(5)), ('wall avg', m.group(1))):
            data.setdefault((wl, name), {}).setdefault(v, []).append(float(val))
units = {'join441': 'ms/441 chunks', 'setblock': 'us/call', 'gen64': 'ms/64 chunks'}
print(f"load average at the start of each run: median {st.median(loads):.1f}, min {min(loads):.1f}, max {max(loads):.1f}\n")
print("| workload | metric | " + " | ".join(variants) + " | speedup vs A: " + ", ".join(v for v in variants if v != 'A') + " |")
print("|---|---|" + "---|" * (len(variants) + 1))
order = ['t500_all', 't500_20', 't2000', 'join441', 'setblock', 'gen64']
for (wl, metric) in sorted(data, key=lambda k: (order.index(k[0]) if k[0] in order else 99, ['cpu avg', 'cpu p99', 'wall avg', 'cpu'].index(k[1]))):
    d = data[(wl, metric)]
    cells, sp = [], []
    for v in variants:
        x = d.get(v, [])
        cells.append(f"{st.median(x):.2f} ({min(x):.2f}-{max(x):.2f}, n={len(x)})" if x else "n/a")
    a = st.median(d['A']) if d.get('A') else None
    for v in variants:
        if v == 'A': continue
        sp.append(f"{a / st.median(d[v]):.3f}x" if a and d.get(v) else "n/a")
    label = metric if metric != 'cpu' else units.get(wl, 'cpu')
    print(f"| {wl} | {label} | " + " | ".join(cells) + " | " + ", ".join(sp) + " |")
