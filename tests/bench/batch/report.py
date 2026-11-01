#!/usr/bin/env python3
"""Turn the logs of tests/bench/batch/sweep.sh (and ab.sh) into markdown tables, so the numbers in docs/PERF-BATCH.md are copied by a program, not by hand.
usage: report.py SWEEP_DIR            one table per scenario log *.log in the directory
       report.py --file LOG           one table for a single ab.sh log
"""
import re, sys, glob, os

NUM = r"([0-9.]+)"
def parse(line):
    f = [x.strip() for x in line.split(" | ")]
    d = {"impl": f[0], "runs": f[1]}
    t = " | ".join(f)
    def g(pat, cast=float):
        m = re.search(pat, t)
        return cast(m.group(1)) if m else None
    d["cpu"] = g(r"CPU " + NUM + " ms"); d["cpu99"] = g(r"CPU [0-9.]+ ms \(p99 " + NUM)
    d["wait"] = g(r"wait " + NUM); d["wall"] = g(r"wall avg " + NUM); d["wall99"] = g(r"p99 " + NUM + r" \| max")
    d["drain"] = g(r"drain " + NUM); d["wal"] = g(r"WAL KB/tick " + NUM); d["plan"] = g(r"plan ms/tick " + NUM); d["stm"] = g(r"stmts/tick " + NUM)
    m = re.search(r"rows ins/upd/del per tick (\d+)/(\d+)/(\d+)", t)
    d["ins"], d["upd"], d["del"] = (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else (None, None, None)
    d["hot"] = g(r"hot% " + NUM)
    return d

def table(path):
    txt = open(path).read()
    if "---- medians" not in txt:
        return f"(no medians in {os.path.basename(path)})\n"
    head, body = txt.split("---- medians", 1)
    title = body.splitlines()[0].strip()
    rows = [parse(l) for l in body.splitlines()[1:] if re.match(r"^(base|batched)", l)]
    base = next((r for r in rows if r["impl"] == "base"), None)
    out = [f"**{os.path.basename(path)[:-4]}** — {title.lstrip('over ')}", "",
           "| implementation | CPU ms/tick (p99) | vs base | wall p99 ms | gateway drain ms | statements/tick | planning ms/tick | WAL KB/tick | rows ins/upd/del per tick | HOT updates |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        delta = "" if r is base or base is None else f"{100 * (r['cpu'] / base['cpu'] - 1):+.0f}%"
        out.append(f"| {r['impl']} | {r['cpu']:.1f} ({r['cpu99']:.0f}) | {delta} | {r['wall99']:.0f} | {r['drain']:.1f} | {r['stm']:.0f} | {r['plan']:.1f} | {r['wal']:.0f} | {r['ins']}/{r['upd']}/{r['del']} | {r['hot']:.0f}% |")
    return "\n".join(out) + "\n"

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--file":
        print(table(sys.argv[2]))
    else:
        for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.log")), key=lambda x: int(re.search(r"s(\d+)_", x).group(1)) if re.search(r"s(\d+)_", x) else 99):
            print(table(p))
