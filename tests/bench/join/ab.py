#!/usr/bin/env python3
"""A/B timing of login storms on several databases, interleaved, median of N repetitions.

usage: tests/bench/join/ab.py [--dbs jb_base,jb_new] [--reps 5] [--scen JOINERS:ONLINE:TICKS ...] [--setting key=value ...]
  scenario "500:0:1"   = 500 players log in during ONE tick into a server with 0 players online
  scenario "500:500:5" = 500 players log in spread over 5 ticks into a server with 500 online (the 500 are joined first, unmeasured)
Each repetition resets the server, joins the online players, warms the caches with one extra join, then measures the storm ticks.
Reports per scenario and database the median of: total ms of the storm ticks, ms in the connection-layer step (net.process), MB produced, WAL KB.
Needs jbench loaded (tests/bench/join/storm.sql + storm_extra.sql); PGHOST/PGPORT/PGUSER as for psql (default /tmp, 54466, postgres).
"""
import argparse, os, statistics, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--dbs", default="jb_base,jb_new"); ap.add_argument("--reps", type=int, default=5)
ap.add_argument("--scen", nargs="+", default=["100:0:1"])
ap.add_argument("--setting", nargs="*", default=[], help="server_property key=value applied before each run (e.g. view-distance=2)")
a = ap.parse_args()
env = dict(os.environ, PGHOST=os.environ.get("PGHOST", "/tmp"), PGPORT=os.environ.get("PGPORT", "54466"), PGUSER=os.environ.get("PGUSER", "postgres"))

def run(db, joiners, online, ticks):
    lines = [f"select jbench.reset(100000);"]
    for kv in a.setting:
        k, v = kv.split("=", 1); lines.append(f"update mc.server_property set value = '{v}' where key = '{k}';")
    nxt = 1
    while nxt <= online:                                   # online players, 100 per tick, unmeasured
        n = min(100, online - nxt + 1); lines.append(f"select 1 from jbench.run_tick({nxt}, {n}, 'O');"); nxt += n
    lines.append(f"select 1 from jbench.run_tick({online + 1}, 1, 'W');")                 # warm-up join (config cache, chunk cache)
    base = online + 2; per = -(-joiners // ticks); left = joiners
    for _ in range(ticks):
        n = min(per, left); left -= n
        lines.append(f"select 'M', * from jbench.run_tick({base}, {n}, 'J');"); base += n
    lines.append("select 'E', count(*) from net.conn where state = 'play';")
    lines.append("select 'X', count(*) from mc.error_log;")
    out = subprocess.run(["psql", "-X", "-q", "-At", "-F", "|", "-v", "ON_ERROR_STOP=1", "-d", db], input="\n".join(lines), text=True, env=env, capture_output=True)
    if out.returncode: sys.exit(out.stderr)
    m = [l.split("|")[1:] for l in out.stdout.splitlines() if l.startswith("M|")]
    e = next(l for l in out.stdout.splitlines() if l.startswith("E|")).split("|")[1]
    x = next(l for l in out.stdout.splitlines() if l.startswith("X|")).split("|")[1]
    f = lambda i: sum(float(r[i]) for r in m)
    return dict(tick=f(0), process=f(1), game=f(2), chunks=f(3), drain=f(4), gw=f(5), mb=f(7), wal=f(8), online=int(e), errors=int(x), worst=max(float(r[0]) for r in m))

dbs = a.dbs.split(",")
for sc in a.scen:
    j, o, t = map(int, sc.split(":"))
    res = {d: [] for d in dbs}
    for rep in range(a.reps):
        for d in dbs:                                       # interleaved: rep 1 of every db, then rep 2 ...
            res[d].append(run(d, j, o, t))
    load = open("/proc/loadavg").read().split()[0]
    print(f"\n== {j} joiners over {t} tick(s) into {o} online, view distance {dict(s.split('=') for s in a.setting).get('view-distance', 'default')}, {a.reps} runs, load average {load}")
    print(f"{'db':10s} {'tick ms':>9s} {'(min-max)':>16s} {'process':>9s} {'chunks':>8s} {'drain':>7s} {'gw drain':>9s} {'MB':>7s} {'WAL KB':>8s} {'worst tick':>11s} {'ms/join':>8s}  online/errors")
    for d in dbs:
        r = res[d]; med = lambda k: statistics.median(x[k] for x in r)
        print(f"{d:10s} {med('tick'):9.0f} {min(x['tick'] for x in r):7.0f}-{max(x['tick'] for x in r):<8.0f} {med('process'):9.0f} {med('chunks'):8.0f} {med('drain'):7.0f} {med('gw'):9.0f} "
              f"{med('mb'):7.0f} {med('wal'):8.0f} {med('worst'):11.0f} {med('tick') / j:8.2f}  {r[0]['online']}/{r[0]['errors']}")
