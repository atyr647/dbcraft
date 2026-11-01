#!/usr/bin/env python3
"""Side-by-side p50 (p99) in microseconds of several result series.   usage: tests/bench/scale/compare.py SERIES [SERIES ...]
Each series is a results/SERIES.json written by run_scale.py (the first size in it is used)."""
import json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
rs = {s: json.load(open(os.path.join(here, "results", f"{s}.json"))) for s in sys.argv[1:]}
first = next(iter(rs.values()))
ops = list(first[next(iter(first))]["ops"])
print("| operation | phase | " + " | ".join(rs) + " |")
print("|---|---|" + "---|" * len(rs))
for op in ops:
    for ph in ("cold", "warm"):
        cells = []
        for s, r in rs.items():
            o = r[next(iter(r))]["ops"].get(op, {}).get(ph)
            cells.append(f"{o['p50_us']:,.0f} ({o['p99_us']:,.0f})" if o else "-")
        print(f"| {op} | {ph} | " + " | ".join(cells) + " |")
for s, r in rs.items():
    x = r[next(iter(r))]
    t = x["sizes"]["chunk_section"]
    print(f"{s}: chunk_section heap+toast+idx = {(t[1] + t[2] + t[3]) / 1048576:.1f} MB for {x['chunks']:,} chunks, load before ops {x.get('load_before_ops')}")
