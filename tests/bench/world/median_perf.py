#!/usr/bin/env python3
"""Run tests/bench/world/perf_chunks.sql several times and print the median, minimum and maximum of each measurement.
usage:  python3 tests/bench/world/median_perf.py DATABASE [RUNS]       (psql settings from PGHOST/PGPORT/PGUSER)
Single runs of these timings vary by up to 2x when other processes use the CPUs; use the median and quote the load average next to it.
"""
import os, re, statistics, subprocess, sys

db = sys.argv[1]
runs = int(sys.argv[2]) if len(sys.argv) > 2 else 5
samples = {}
labels = {}
for r in range(runs):
    out = subprocess.run(["psql", "-X", "-d", db, "-f", "tests/bench/world/perf_chunks.sql"], capture_output=True, text=True).stderr
    for line in out.splitlines():
        m = re.search(r"NOTICE:\s+([A-D]\d)\s+(.*?)\s*:\s*(.*)$", line)
        if not m:
            continue
        code, label, rest = m.groups()
        v = None
        for pat, unit in ((r"^([\d.]+) ms \(", "ms"), (r"([\d.]+) ms per (?:chunk|edit\+rebuild)", "ms"), (r"([\d.]+) us per (?:chunk|edit|read)", "us"),
                          (r"chunks in ([\d.]+) ms", "ms"), (r"changed, ([\d.]+) ms", "ms"), (r"in \d+ sections\s*:\s*([\d.]+) ms", "ms"), (r"^([\d.]+) ms", "ms")):
            mm = re.search(pat, rest)
            if mm:
                v, u = float(mm.group(1)), unit
                break
        if v is None:
            mm = re.search(r"\(.*?\)\s*$", rest)
            continue
        samples.setdefault(code, []).append(v)
        labels[code] = (label.strip(), u)
print(f"load average before: {os.getloadavg()[0]:.2f}   runs: {runs}")
for code in sorted(samples):
    v = samples[code]
    label, u = labels[code]
    print(f"{code}  {label:48s} median {statistics.median(v):9.2f} {u}   min {min(v):9.2f}   max {max(v):9.2f}")
