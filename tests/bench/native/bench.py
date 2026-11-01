#!/usr/bin/env python3
"""Native deflate vs the SQL deflate: ratio and time, interleaved, median of N rounds.

usage:  PGHOST=/tmp PGPORT=54433 PGUSER=postgres PGDATABASE=dbcraft_zlib  tests/bench/native/bench.py [ROUNDS=5]
needs:  the dbcraft_zlib extension, and  psql -f tests/bench/native/setup.sql  already run in that database (loads the real terrain packets).
Every variant is timed INSIDE Postgres (clock_timestamp around a loop over all items of its data set, a different input per call: no constant folding), then
the variants are run in a shuffled order per round so that background load (other processes share this machine) hits all of them alike.
Prints markdown tables and writes tests/bench/native/results.json.
"""
import json, os, random, re, statistics, subprocess, sys, time

ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 5
here = os.path.dirname(os.path.abspath(__file__))

def psql(sql):
    p = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True)
    if p.returncode:
        sys.exit("psql failed:\n" + p.stderr)
    return p.stderr + p.stdout

def load1():
    return float(open("/proc/loadavg").read().split()[0])

# data sets: (table, column, id column, p expression used in variant text)
SETS = {
    "real": dict(sql="select payload as p, id from bench.real_pk order by id", title="real vanilla terrain chunk packets (49, avg 51.6 KB)"),
    "slice": dict(sql="select slice as p, pk as id from bench.real_slices order by pk, i", title="4 KiB slices of those packets (641)"),
    "flat": dict(sql="select payload as p, id from bench.flat_pk order by id", title="flat-world chunk packets (40, avg 9.3 KB)"),
}

def frags(sl, lvl):    # a zlib stream built from independent sync-flushed fragments of sl bytes, with the Adler-32 of the whole
    return (f"('\\x7801'::bytea || (select string_agg(dbcraft_zlib.deflate_fragment(substring(r.p from 1 + i * {sl} for {sl}), {lvl}, i = (octet_length(r.p) - 1) / {sl}), ''::bytea order by i) "
            f"from generate_series(0, (octet_length(r.p) - 1) / {sl}) i) || substring(int8send(dbcraft_zlib.adler32(r.p)) from 5 for 4))")

V = {}      # name -> (applies to sets, expression returning bytea, or ('perform', expr))
for lvl in (1, 6, 9):
    V[f"zlib L{lvl}"] = (("real", "slice", "flat"), f"dbcraft_zlib.deflate_zlib(r.p, {lvl}, 'zlib')")
    V[f"libdeflate L{lvl}"] = (("real", "slice", "flat"), f"dbcraft_zlib.deflate_zlib(r.p, {lvl}, 'libdeflate')")
V["SQL deflate (sql/440)"] = (("real", "slice", "flat"), "mc.deflate_zlib_sql(r.p)")
for lvl in (1, 6):
    V[f"fragments 4 KiB, zlib L{lvl}"] = (("real",), frags(4096, lvl))
    V[f"fragments 16 KiB, zlib L{lvl}"] = (("real",), frags(16384, lvl))
    V[f"one fragment (final), zlib L{lvl}"] = (("slice",), f"dbcraft_zlib.deflate_fragment(r.p, {lvl}, true)")
V["adler32 native"] = (("real",), ("perform", "dbcraft_zlib.adler32(r.p)"))
V["adler32 SQL (sql/440)"] = (("real",), ("perform", "mc.adler32_sql(r.p)"))
V["assemble packet from cached L6 4 KiB fragments + native adler32 of whole"] = (("real",),
    "('\\x7801'::bytea || (select string_agg(f.frag, ''::bytea order by f.i) from bench.frag_cache f where f.pk = r.id) || substring(int8send(dbcraft_zlib.adler32(r.p)) from 5 for 4))")
V["assemble packet from cached fragments + folded per-fragment Adler-32"] = (("real",),
    "('\\x7801'::bytea || (select string_agg(f.frag, ''::bytea order by f.i) from bench.frag_cache f where f.pk = r.id) || substring(int8send("
    "(with recursive q(i, a) as (select 0, f0.adler from bench.frag_cache f0 where f0.pk = r.id and f0.i = 0 union all select q.i + 1, dbcraft_zlib.adler32_combine(q.a, g.adler, g.len) "
    "from q join bench.frag_cache g on g.pk = r.id and g.i = q.i + 1) select a from q order by i desc limit 1)) from 5 for 4))")

def do_block(set_name, expr):
    perform = isinstance(expr, tuple)
    e = expr[1] if perform else expr
    body = (f"perform {e};" if perform else f"zb := zb + octet_length({e});")
    return f"""set jit = off;
do $b$ declare r record; n int := 0; rb bigint := 0; zb bigint := 0; t0 timestamptz; ms numeric;
begin
  t0 := clock_timestamp();
  for r in {SETS[set_name]['sql']} loop
    {body} rb := rb + octet_length(r.p); n := n + 1;
  end loop;
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'RESULT|%|%|%|%', n, rb, zb, ms;
end $b$;"""

print("preparing fragment cache ...", file=sys.stderr)
psql("""drop table if exists bench.frag_cache;
create table bench.frag_cache as
select s.pk, s.i, dbcraft_zlib.deflate_fragment(s.slice, 6, s.i = m.mx) as frag, dbcraft_zlib.adler32(s.slice) as adler, octet_length(s.slice)::bigint as len
  from bench.real_slices s join (select pk, max(i) mx from bench.real_slices group by pk) m using (pk);
create index on bench.frag_cache (pk, i); analyze bench.frag_cache;""")
print("backend:", psql("select dbcraft_zlib.backend()").strip().splitlines()[0] if False else "", file=sys.stderr)

jobs = [(s, name) for name, (sets, _) in V.items() for s in sets]
res = {j: [] for j in jobs}
loads = []
for rnd in range(ROUNDS):
    order = jobs[:]; random.shuffle(order)
    loads.append(load1())
    for (s, name) in order:
        out = psql(do_block(s, V[name][1]))
        m = re.search(r"RESULT\|(\d+)\|(\d+)\|(\d+)\|([\d.]+)", out)
        if not m:
            sys.exit(f"no result for {s}/{name}:\n{out}")
        n, rb, zb, ms = int(m[1]), int(m[2]), int(m[3]), float(m[4])
        res[(s, name)].append((ms / n, rb, zb))
    print(f"round {rnd + 1}/{ROUNDS} done, load {loads[-1]:.2f}", file=sys.stderr)

up = open("/proc/loadavg").read().strip()
report = {"rounds": ROUNDS, "loadavg_at_round_start": loads, "loadavg_end": up, "backend": psql("select dbcraft_zlib.backend()").strip(), "results": {}}
print(f"\nrounds={ROUNDS}  load average at the start of each round: {', '.join(f'{x:.2f}' for x in loads)}  (4 CPUs, shared with other jobs)\n")
for s in SETS:
    print(f"### {SETS[s]['title']}\n")
    print("| variant | ms per item (median) | min | max | compressed / input | ratio |")
    print("|---|---|---|---|---|---|")
    for (js, name), runs in res.items():
        if js != s:
            continue
        ms = [r[0] for r in runs]
        rb, zb = runs[0][1], runs[0][2]
        ratio = f"{rb / zb:.2f}x" if zb else "-"
        comp = f"{zb / 1024:.0f} KiB / {rb / 1024:.0f} KiB" if zb else "-"
        print(f"| {name} | {statistics.median(ms):.3f} | {min(ms):.3f} | {max(ms):.3f} | {comp} | {ratio} |")
        report["results"][f"{s}|{name}"] = dict(median_ms=statistics.median(ms), min_ms=min(ms), max_ms=max(ms), input_bytes=rb, output_bytes=zb)
    print()
json.dump(report, open(os.path.join(here, "results.json"), "w"), indent=1)
