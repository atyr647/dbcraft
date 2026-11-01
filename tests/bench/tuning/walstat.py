#!/usr/bin/env python3
"""Attribute WAL bytes to resource managers, record types and relations.

usage: walstat.py DATA_DIR START_LSN END_LSN PORT [TICKS]
Runs pg_waldump over [START_LSN, END_LSN) of DATA_DIR/pg_wal, maps relfilenodes to relation names through the running cluster on PORT (database dbcraft,
user postgres, socket /tmp), and prints the biggest contributors.  With TICKS, also KB per tick.  Standard library only.
"""
import collections, glob, os, re, subprocess, sys

data, lsn0, lsn1, port = sys.argv[1:5]
ticks = int(sys.argv[5]) if len(sys.argv) > 5 else 0
pgbin = sorted(glob.glob("/usr/lib/postgresql/*/bin"))[-1]
q = "select c.relfilenode, c.relnamespace::regnamespace || '.' || c.relname from pg_class c where c.relfilenode <> 0 union all select 0, 'x'"
names = {}
out = subprocess.run(["psql", "-X", "-At", "-F", "|", "-h", "/tmp", "-p", port, "-U", "postgres", "dbcraft", "-c", q], capture_output=True, text=True).stdout
for line in out.splitlines():
    a, _, b = line.partition("|")
    if a.isdigit(): names[int(a)] = b
cmd = [pgbin + "/pg_waldump", "-p", os.path.join(data, "pg_wal"), "-s", lsn0, "-e", lsn1]
if os.geteuid() == 0:
    cmd = ["su", "postgres", "-s", "/bin/bash", "-c", " ".join(cmd)]
p = subprocess.run(cmd, capture_output=True, text=True)
by_rmgr = collections.Counter(); by_rec = collections.Counter(); by_rel = collections.Counter(); fpi_rel = collections.Counter(); nrec = collections.Counter()
rx = re.compile(r"rmgr: (\S+)\s+len \(rec/tot\):\s+(\d+)/\s*(\d+),.*?desc: (\S+)")
rel_rx = re.compile(r"blkref #\d+: rel (\d+)/(\d+)/(\d+)")
total = 0
for line in p.stdout.splitlines():
    m = rx.search(line)
    if not m: continue
    rmgr, rec, tot, desc = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
    total += tot; by_rmgr[rmgr] += tot; by_rec[(rmgr, desc)] += tot; nrec[(rmgr, desc)] += 1
    rels = rel_rx.findall(line)
    key = names.get(int(rels[0][2]), "rel " + rels[0][2]) if rels else "(no relation: " + rmgr + ")"
    by_rel[key] += tot
    if "FPW" in line or "FPI" in line: fpi_rel[key] += tot
print(f"total {total / 1024:.0f} KB" + (f", {total / 1024 / ticks:.1f} KB per tick over {ticks} ticks" if ticks else ""))
print("by resource manager:", ", ".join(f"{k} {v / 1024:.0f} KB" for k, v in by_rmgr.most_common(8)))
print("top record types:")
for (rm, d), v in by_rec.most_common(12): print(f"  {rm:10s} {d:22s} {v / 1024:8.0f} KB  {nrec[(rm, d)]:8d} records")
print("top relations:")
for k, v in by_rel.most_common(15): print(f"  {k:40s} {v / 1024:8.0f} KB  (full-page images in it: {fpi_rel[k] / 1024:.0f} KB)")
if p.returncode and not p.stdout: print(p.stderr[:500])
