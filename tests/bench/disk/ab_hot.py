#!/usr/bin/env python3
"""ab_hot.py ROUNDS OUTFILE db1 db2 ...  (run from the repository root; DBCRAFT_PGPORT selects the cluster, socket directory /tmp)
Alternates tests/bench/disk/hot.sql over the databases; per label the median and range of the CPU time of the hot paths touched by sql/950; writes OUTFILE (docs/PERF-DISK.md)."""
import os, re, statistics, subprocess, sys
W = "tests/bench/disk"
rounds = int(sys.argv[1]); out = sys.argv[2]; dbs = sys.argv[3:]
res = {}; labels = []
for r in range(rounds):
    for d in (dbs if r % 2 == 0 else dbs[::-1]):
        p = subprocess.run(["psql", "-h", "/tmp", "-p", os.environ.get("DBCRAFT_PGPORT", "54329"), "-U", "postgres", "-X", "-q", "-d", d, "-f", W + "/hot.sql"], capture_output=True, text=True)
        for line in p.stderr.splitlines():
            m = re.search(r"NOTICE:\s+(H\d [\w ]+?): ([\d. ]+) (ms|us)", line)
            if not m: continue
            lab, vals, unit = m.groups()
            key = (lab, unit)
            if key not in labels: labels.append(key)
            res.setdefault((d, key), []).extend(float(x) for x in vals.split())
        if p.returncode != 0: open(out + ".err", "a").write("ERR %s %s\n" % (d, p.stderr[-400:]))
lines = ["%-28s" % "" + "".join("%-36s" % d for d in dbs) + " ratio (last/first median)"]
for key in labels:
    cells = []; meds = []
    for d in dbs:
        v = res.get((d, key), [])
        if v: meds.append(statistics.median(v))
        cells.append("%9.1f [%8.1f-%8.1f] n=%d" % (statistics.median(v), min(v), max(v), len(v)) if v else "n/a")
    lines.append("%-24s %-3s" % (key[0], key[1]) + "".join("%-36s" % c for c in cells) + ("  %.2f" % (meds[-1] / meds[0]) if len(meds) > 1 else ""))
open(out, "w").write("\n".join(lines) + "\n")
