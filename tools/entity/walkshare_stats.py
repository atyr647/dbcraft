#!/usr/bin/env python3
"""Statistics of a tools/entity/vanilla_walkshare.py --series file: walking share, run lengths, gaps, speed of the cows near the player.  usage: walkshare_stats.py FILE [TAG]"""
import json, statistics as st, sys

tag = sys.argv[2] if len(sys.argv) > 2 else "near"
runs = []; gaps = []; speeds = []; total = 0
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["tag"] != tag: continue
    cur = gap = 0
    for x in r["d"]:
        total += 1
        if x > 0.5:
            speeds.append(x)
            if gap: gaps.append(gap); gap = 0
            cur += 1
        else:
            if cur: runs.append(cur); cur = 0
            gap += 1
n = len(speeds); sp = sorted(speeds)
print(f"{tag}: cow-seconds {total}, walking share {n / max(total, 1):.3f}")
if runs: print(f"walking runs: {len(runs)}, mean {st.mean(runs):.1f} s, median {st.median(runs)} s")
if gaps: print(f"standing gaps: {len(gaps)}, mean {st.mean(gaps):.1f} s, median {st.median(gaps)} s")
if n: print("blocks per second while moving, quantiles 10/25/50/75/90/99:", [round(sp[int(q * (n - 1))], 2) for q in (.1, .25, .5, .75, .9, .99)])
