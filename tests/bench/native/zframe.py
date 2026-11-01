#!/usr/bin/env python3
"""The real code path: mc.z_frame(payload) over the 49 real terrain packets with the SQL and the native implementation, interleaved, median of N rounds.

usage:  PGHOST=/tmp PGPORT=54433 PGUSER=postgres PGDATABASE=dbcraft_zlib  tests/bench/native/zframe.py [ROUNDS=5]
Every measurement is its own top-level statement (and transaction): Postgres keeps the plan of a SQL function for the length of a transaction, so switching
the implementation with mc.select_deflate inside one DO block would go on using the old plan (that is a property of the benchmark, not of the extension; a new
transaction picks the new definition up).  The compressed header bytes are checked so a run can never silently measure the wrong implementation.
"""
import random, re, statistics, subprocess, sys

ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 5

def psql(sql):
    p = subprocess.run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True)
    if p.returncode:
        sys.exit(p.stderr)
    return p.stdout.strip()

timing = """set jit = off; do $$ declare r record; t0 timestamptz; ms numeric; raw bigint := 0; z bigint := 0; n int := 0;
begin
  t0 := clock_timestamp();
  for r in select payload p from bench.real_pk order by id loop z := z + octet_length(mc.z_frame(r.p)); raw := raw + octet_length(r.p); n := n + 1; end loop;
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'R|%|%|%|%', n, raw, z, ms;
end $$;"""

def one(impl, level):
    psql(f"select mc.select_deflate('{impl}', {level})")
    out = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", timing], capture_output=True, text=True)
    m = re.search(r"R\|(\d+)\|(\d+)\|(\d+)\|([\d.]+)", out.stderr)
    if not m:
        sys.exit(out.stderr)
    # which implementation actually produced the bytes: SQL writes the zlib header 78 01 first; zlib/libdeflate at level 6 write 78 9c, level 9 78 da, level 1 78 01
    hdr = psql("select encode(substring(mc.deflate_zlib('\\x414141414141414141'::bytea) from 1 for 2), 'hex')")
    return int(m[1]), int(m[2]), int(m[3]), float(m[4]), hdr

variants = [("sql", 0), ("native", 1), ("native", 6), ("native", 9)]
res = {v: [] for v in variants}
for rnd in range(ROUNDS):
    order = variants[:]; random.shuffle(order)
    for v in order:
        res[v].append(one(*v))
    print(f"round {rnd + 1}/{ROUNDS}, load {open('/proc/loadavg').read().split()[0]}", file=sys.stderr)
psql("select mc.select_deflate('native', 6)")
print(f"mc.z_frame over the {res[variants[0]][0][0]} real terrain packets, {ROUNDS} rounds interleaved (load average now {open('/proc/loadavg').read().split()[0]}, 4 CPUs shared)\n")
print("| implementation | ms per packet (median) | min | max | compressed / input | ratio | header bytes seen |")
print("|---|---|---|---|---|---|---|")
for (impl, lvl), runs in res.items():
    n, raw, z, _, hdr = runs[0]
    ms = [r[3] / r[0] for r in runs]
    name = "SQL (sql/440)" if impl == "sql" else f"native zlib/libdeflate L{lvl} ('auto' = libdeflate)"
    print(f"| {name} | {statistics.median(ms):.3f} | {min(ms):.3f} | {max(ms):.3f} | {z / 1024:.0f} KiB / {raw / 1024:.0f} KiB | {raw / z:.2f}x | {hdr} |")
