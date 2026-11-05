#!/usr/bin/env python3
"""Development helper: apply ONLY the named functions of a SQL file to the database the PG* variables name.  Re-applying a whole file would undo what a later file
redefines (sql/432 defines mc.refresh_visibility and net.stream_chunks, which 468 and 436 replace); this applies just the `create or replace function` statements asked for.

usage: tests/e2e/apply_fn.py sql/432_tick_perf_world.sql mc.apply_block_actions [schema.name ...]
Restart the dev gateway afterwards (tests/e2e/vis_dev.sh stop; start): a long-lived backend keeps cached plans of the old function.
"""
import re, subprocess, sys
path, names = sys.argv[1], set(sys.argv[2:])
text = open(path).read()
done = set()
for m in re.finditer(r"create\s+or\s+replace\s+function\s+([a-z_]+\.[a-z_0-9]+)\s*\(.*?\$\$;", text, re.S | re.I):
    if m.group(1) in names:
        p = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=m.group(0).encode(), capture_output=True)
        if p.returncode: sys.exit(p.stderr.decode())
        done.add(m.group(1))
print("applied:", ", ".join(sorted(done)), "| not found:", ", ".join(sorted(names - done)) or "-")
