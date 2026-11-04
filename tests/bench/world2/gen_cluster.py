#!/usr/bin/env python3
"""What dbcraft spends to generate N x N chunks of dbcraft:noise terrain, measured the way vanilla_gen.py measures vanilla (docs/PERF-WORLD2.md): the CPU time of the WHOLE
PostgreSQL process tree (backends, WAL writer, checkpointer, background writer, autovacuum), not only the generating backend, plus wall time, plus the cost of making it
durable (a CHECKPOINT, the counterpart of vanilla's `save-all flush`).  Chunks are generated with their light and their packet (what the generation queue's worker does).
usage: gen_cluster.py --port 59347 --db w2 --pgdata /dev/shm/dbc-world2-pg --size 100 [--origin 400] [--per-call 256] [--workers 1] [--out FILE.json]
--workers N: N psql sessions generate disjoint row bands at the same time (the queue's loops are independent; the tick is not involved).
"""
import argparse, json, os, subprocess, sys, threading, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "scoreboard"))
import common as C


def psql(a, sql):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", str(a.port), "-U", "postgres", "-d", a.db, "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    return r.stdout.strip()


def tree_cpu_s(pm):
    """CPU seconds of the postmaster tree including the backends that already exited (the postmaster's cutime and cstime hold their time once it has reaped them)."""
    f = open(f"/proc/{pm}/stat").read().rsplit(")", 1)[1].split()
    tot = (int(f[11]) + int(f[12]) + int(f[13]) + int(f[14])) / C.CLK
    for p in C.descendants(pm):
        if p != pm:
            tot += C.proc_cpu(p)[0]
    return tot


def postmaster(a):
    return int(open(os.path.join(a.pgdata, "postmaster.pid")).readline())


def worker(a, rows, per_call, out):
    # one psql session per worker: rows of chunks (cz values), per_call chunks per generator call
    n = 0
    for cz in rows:
        for cx0 in range(a.origin, a.origin + a.size, per_call):
            cx1 = min(cx0 + per_call - 1, a.origin + a.size - 1)
            n += int(psql(a, f"select mc.generate_noise_batch('minecraft:overworld', array_agg(x), array_agg({cz})) from generate_series({cx0}, {cx1}) x"))
    out.append(n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True); ap.add_argument("--db", default="w2"); ap.add_argument("--pgdata", required=True)
    ap.add_argument("--size", type=int, default=100); ap.add_argument("--origin", type=int, default=400); ap.add_argument("--per-call", type=int, default=100)
    ap.add_argument("--workers", type=int, default=1); ap.add_argument("--out", default="")
    a = ap.parse_args()
    C.PGDATA = a.pgdata
    pm = postmaster(a)
    psql(a, "update mc.server_property set value = 'dbcraft:noise' where key = 'dbcraft.generator'")
    psql(a, "checkpoint")
    print("load", open("/proc/loadavg").read().split()[:3], flush=True)
    c0 = tree_cpu_s(pm); t0 = time.time()
    rows = list(range(a.origin, a.origin + a.size))
    outs, th = [], []
    for w in range(a.workers):
        t = threading.Thread(target=worker, args=(a, rows[w::a.workers], a.per_call, outs)); t.start(); th.append(t)
    for t in th:
        t.join()
    c1 = tree_cpu_s(pm); t1 = time.time()
    n = sum(outs)
    psql(a, "checkpoint")
    c2 = tree_cpu_s(pm); t2 = time.time()
    res = {"chunks": n, "workers": a.workers, "gen_wall_s": t1 - t0, "gen_cpu_ms": (c1 - c0) * 1000, "ms_per_chunk_cpu": (c1 - c0) * 1000 / max(1, n), "ms_per_chunk_wall": (t1 - t0) * 1000 / max(1, n),
           "checkpoint_wall_s": t2 - t1, "checkpoint_cpu_ms": (c2 - c1) * 1000, "total_cpu_ms_per_chunk": (c2 - c0) * 1000 / max(1, n), "load_after": open("/proc/loadavg").read().split()[:3]}
    print(json.dumps(res, indent=1))
    if a.out:
        json.dump(res, open(a.out, "w"))


main()
