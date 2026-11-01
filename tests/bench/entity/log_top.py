#!/usr/bin/env python3
"""Top statements by duration from a PostgreSQL log written by auto_explain.   usage: log_top.py LOGFILE [N]"""
import re, sys
t = open(sys.argv[1]).read()
n = int(sys.argv[2]) if len(sys.argv) > 2 else 12
rows = []
for e in re.split(r"\n(?=\d{4}-\d\d-\d\d )", t):
    m = re.search(r"duration: ([\d.]+) ms", e)
    if m:
        q = re.search(r"Query Text: (.{0,110})", e, re.S)
        rows.append((float(m.group(1)), q.group(1).replace("\n", " ").replace("\t", " ") if q else ""))
for d, q in sorted(rows, reverse=True)[:n]:
    print("%8.1f ms  %s" % (d, q))
