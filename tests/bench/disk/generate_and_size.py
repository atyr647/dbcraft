#!/usr/bin/env python3
"""generate_and_size.py SRC_DB NEW_DB kind(flat|noise)  (repository root; DBCRAFT_PGPORT): clone SRC_DB (a migrated, empty-world database) to NEW_DB, generate the world, report time, WAL bytes, sizes."""
import os, subprocess, sys, time
W = "tests/bench/disk"
src, db, kind = sys.argv[1:4]
base = ["psql", "-h", "/tmp", "-p", os.environ.get("DBCRAFT_PGPORT", "54329"), "-U", "postgres", "-X", "-q", "-At"]
def q(sql, d=db):
    r = subprocess.run(base + ["-d", d, "-c", sql], capture_output=True, text=True)
    if r.returncode != 0: print("ERR", sql[:80], r.stderr[-400:])
    return r.stdout.strip()
q("drop database if exists %s" % db, "postgres"); q("create database %s template %s" % (db, src), "postgres")
q("checkpoint")
lsn0 = q("select pg_current_wal_lsn()")
t = time.time()
if kind == "flat":
    q("select mc.generate_batch('minecraft:overworld', array_agg(x), array_agg(z)) from generate_series(-50, 49) x, generate_series(-50, 49) z"); n = 10000
else:
    q("update mc.server_property set value = 'dbcraft:noise' where key = 'dbcraft.generator'")
    q("select sum(n) from (select mc.generate_batch('minecraft:overworld', xs, zs) n from (select array_agg(x) xs, array_agg(z) zs from (select x, z, (row_number() over (order by x, z) - 1) / 50 g from generate_series(-25, 24) x, generate_series(-20, 19) z) q group by g) r) t"); n = 2000
el = time.time() - t
wal = int(q("select pg_wal_lsn_diff(pg_current_wal_lsn(), '%s')" % lsn0))
t = time.time(); q("checkpoint"); ck = time.time() - t
print("%s %s: %d chunks in %.2f s (%.3f ms/chunk), WAL %.1f MiB (%.0f B/chunk), checkpoint %.3f s" % (db, kind, n, el, el * 1000 / n, wal / 1048576, wal / n, ck), flush=True)
sys.stdout.flush()
print(subprocess.run(base + ["-d", db, "-f", W + "/sizes.sql"], capture_output=True, text=True).stdout)
