#!/usr/bin/env python3
"""Aggregate the output of tests/bench/mobs2/ae.sql: the statements of one entity tick, slowest first.   usage: ae_summary.py out.txt [N]"""
import re, sys

txt = open(sys.argv[1]).read()
n = int(sys.argv[2]) if len(sys.argv) > 2 else 40
parts = re.split(r"\n?psql:[^\n]*LOG:  duration: ", txt)[1:]
rows = []
for p in parts:
    m = re.match(r"([\d.]+) ms  plan:\nQuery Text: (.*?)\n(?:Aggregate|Insert|Update|Delete|Result|Nested|Hash|Seq|Index|Sort|Limit|Subquery|CTE|Function|ProjectSet|Bitmap|Merge|Gather|GroupAggregate|HashAggregate|WindowAgg|Values|Materialize|Unique|Append|SetOp)", p, re.S)
    if m:
        rows.append((float(m.group(1)), re.sub(r"\s+", " ", m.group(2))[:170]))
rows.sort(reverse=True)
print(len(rows), "statements, sum of durations (nested ones counted too)", round(sum(r[0] for r in rows), 1), "ms")
for d, q in rows[:n]:
    print(f"{d:7.2f}  {q}")
