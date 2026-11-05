#!/usr/bin/env python3
"""A/B of the chunk path before and after the chunk cursors (sql/1020, docs/PERF-STORM.md "Round 3"), in one database, interleaved.

usage: run.py [--reps 3] [--xmod 25] [--ref f09cc54]      env: PGHOST (default /tmp), PGPORT (default 54329), PGUSER (postgres), PGDATABASE (dbcraft)
The database must be migrated (the tree's sql/ applied); the bench installs the functions net.hook_chunks, net.stream_chunks, mc.deliver_ready_chunks of the commit --ref
(the last one before the cursors: the rows implementation) and of the working tree, alternately, and runs micro.sql after each: 50 joins at view distance 10 into an explored world
(hook_chunks, then the delivery of their tails under the default budgets) and 500 walkers of which 1/xmod cross a chunk border every tick (stream_chunks, async generation).
xmod 25 = 20 crossings a tick (460 chunks, within the 600 a tick budget); xmod 14 = 35 a tick (805 chunks: a backlog).  It creates chunks (flat) around the origin and
leaves the database without players.  Not for a database that holds a world you want to keep."""
import argparse, os, re, subprocess, sys, tempfile

ap = argparse.ArgumentParser()
ap.add_argument("--reps", type=int, default=3); ap.add_argument("--xmod", type=int, default=25); ap.add_argument("--ref", default="f09cc54")
a = ap.parse_args()
root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
env = dict(os.environ, PGHOST=os.environ.get("PGHOST", "/tmp"), PGPORT=os.environ.get("PGPORT", "54329"), PGUSER=os.environ.get("PGUSER", "postgres"), PGDATABASE=os.environ.get("PGDATABASE", "dbcraft"))
SRC = (("sql/430_chunk_queue.sql", "net.hook_chunks"), ("sql/436_stream_chunks_merge.sql", "net.stream_chunks"), ("sql/791_join_chunk_budget.sql", "mc.deliver_ready_chunks"))


def function_text(text, name):
    start = text.index("create or replace function " + name + "(")
    o1 = text.index("$$", start)
    o2 = text.index("$$", o1 + 2)
    return text[start:text.index(";", o2) + 1]


def install(impl):
    for path, name in SRC:
        if impl == "old":
            text = subprocess.run(["git", "show", "%s:%s" % (a.ref, path)], cwd=root, capture_output=True, text=True, check=True).stdout
        else:
            text = open(os.path.join(root, path)).read()
        r = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", function_text(text, name)], env=env, capture_output=True, text=True)
        if r.returncode:
            sys.exit("install %s %s: %s" % (impl, name, r.stderr[-300:]))


for rep in range(a.reps):
    for impl in ("old", "new"):
        install(impl)
        r = subprocess.run(["psql", "-X", "-q", "-A", "-t", "-F", " | ", "-v", "xmod=%d" % a.xmod, "-f", os.path.join(root, "tests/bench/chunkcursor/micro.sql")], env=env, capture_output=True, text=True)
        print("%s rep %d (load %s)" % (impl, rep, open("/proc/loadavg").read().split()[0]), flush=True)
        for l in r.stdout.splitlines():
            if re.match(r"^(A joins|B walkers|F ) ?", l) and " | " in l and "calls 0" not in l:
                print("   ", l, flush=True)
        if r.returncode:
            print(r.stderr[-400:])
