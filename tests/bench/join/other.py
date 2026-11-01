#!/usr/bin/env python3
"""Reconnect storms, idle ticks and steady churn on several databases, interleaved, median of N repetitions.

usage: tests/bench/join/other.py [--dbs jb_base,jb_new] [--reps 3] [--online 300] [--k 100]
  reconnect-dup   K of the ONLINE players come back on new connections while their old connections are still open (duplicate login kicks the old ones)
  reconnect-gone  K of the online players disconnect and come back in the same tick
  idle            20 ticks with ONLINE players connected and nothing happening (the cost of an idle server)
  churn           20 ticks in which 5 players leave and 5 new ones join every tick, with ONLINE players connected
Prints the median tick time (ms) per scenario and database.  Needs jbench loaded (storm.sql + storm_extra.sql).
"""
import argparse, os, statistics, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--dbs", default="jb_base,jb_new"); ap.add_argument("--reps", type=int, default=3)
ap.add_argument("--online", type=int, default=300); ap.add_argument("--k", type=int, default=100)
a = ap.parse_args()
env = dict(os.environ, PGHOST=os.environ.get("PGHOST", "/tmp"), PGPORT=os.environ.get("PGPORT", "54466"), PGUSER=os.environ.get("PGUSER", "postgres"))

def psql(db, script):
    out = subprocess.run(["psql", "-X", "-q", "-At", "-F", "|", "-v", "ON_ERROR_STOP=1", "-d", db], input=script, text=True, env=env, capture_output=True)
    if out.returncode: sys.exit(out.stderr)
    return [l.split("|") for l in out.stdout.splitlines() if l]

def setup(online):
    lines = ["select jbench.reset(100000);"]
    nxt = 1
    while nxt <= online:
        n = min(100, online - nxt + 1); lines.append(f"select 1 from jbench.run_tick({nxt}, {n}, 'O');"); nxt += n
    lines.append(f"select 1 from jbench.run_tick({online + 1}, 1, 'W');")
    return lines

def run(db, scen):
    L = setup(a.online)
    if scen in ("reconnect-dup", "reconnect-gone"):
        mode = "dup" if scen.endswith("dup") else "gone"
        L.append(f"select 'M', ms_tick, mb from jbench.reconnect_tick(1, {a.k}, 10000, 'O', '{mode}');")
    elif scen == "idle":
        L += [f"select 'M', ms_tick from jbench.run_tick(0, 0);" for _ in range(20)]
    elif scen == "churn":
        base = a.online + 2
        for i in range(20):
            L.append(f"select jbench.leave({1 + i * 5}, 5);")
            L.append(f"select 'M', ms_tick from jbench.run_tick({base}, 5, 'C');"); base += 5
    r = psql(db, "\n".join(L))
    ms = [float(x[1]) for x in r if x and x[0] == "M"]
    return statistics.median(ms), sum(ms)

# helper used by the churn scenario: disconnect p_n consecutive connections
for db in a.dbs.split(","):
    psql(db, "create or replace function jbench.leave(p_from int, p_n int) returns void language sql as $$ select net.on_disconnect(g) from generate_series(p_from, p_from + p_n - 1) g $$;")
print(f"online {a.online}, K {a.k}, {a.reps} runs each (interleaved); median tick ms")
for scen in ("reconnect-dup", "reconnect-gone", "idle", "churn"):
    res = {d: [] for d in a.dbs.split(",")}
    for _ in range(a.reps):
        for d in res: res[d].append(run(d, scen))
    cols = "  ".join(f"{d}: {statistics.median(x[0] for x in res[d]):8.1f} ms/tick (total {statistics.median(x[1] for x in res[d]):8.0f})" for d in res)
    print(f"{scen:15s} {cols}")
