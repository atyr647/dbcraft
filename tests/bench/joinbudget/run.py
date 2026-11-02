#!/usr/bin/env python3
"""Paced login-storm runs against the join budget (see storm.sql, docs/PERF-JOINBUDGET.md).

usage: run.py --joiners 200 --online 200 --budget 40|off [--maxwait 12] [--initial 3] [--arrive 20] [--vd 2] [--side 4] [--tick default|batched]
              [--walk 1.0] [--max-ticks 900] [--db dbcraft] [--label text] [--json]
Environment: JB_PORT (default 54755), JB_DB (database, default dbcraft).  Prints one summary line (and JSON with --json).
Each tick is one `select jbp.step(t)` statement fed to ONE psql session on stdin, so each is its own transaction like one gateway tick.
"""
import argparse, json, os, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--joiners", type=int, default=200); ap.add_argument("--online", type=int, default=0)
ap.add_argument("--budget", default="40"); ap.add_argument("--maxwait", default="12"); ap.add_argument("--initial", default="3")
ap.add_argument("--arrive", type=int, default=1000, help="milliseconds over which the joiners arrive")
ap.add_argument("--vd", type=int, default=2); ap.add_argument("--side", type=int, default=30, help="the online players are spread over side x side chunks")
ap.add_argument("--tick", default="default"); ap.add_argument("--walk", type=float, default=1.0)
ap.add_argument("--max-ticks", type=int, default=1500); ap.add_argument("--db", default=os.environ.get("JB_DB", "dbcraft"))
ap.add_argument("--label", default=""); ap.add_argument("--json", action="store_true")
a = ap.parse_args()
port = os.environ.get("JB_PORT", "54755")
base = ["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", port, "-U", "postgres", a.db]

def sql(q, stdin=None):
    p = subprocess.run(base + (["-f", "-"] if stdin is not None else ["-c", q]), input=stdin, capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"psql failed: {p.stderr[:600]}")
    return p.stdout.strip()

for k, v in (("dbcraft.join-budget-ms", a.budget), ("dbcraft.join-max-wait-s", a.maxwait), ("dbcraft.join-initial-rate", a.initial)):
    sql(f"update mc.server_property set value = '{v}' where key = '{k}'")
sql(f"select jbp.reset({a.online}, {a.side}, {a.vd}, {a.joiners}, {a.arrive}, '{a.tick}')")

t = 0
while t < a.max_ticks:
    batch = range(t + 1, min(t + 20, a.max_ticks) + 1)
    sql("", stdin="".join(f"select jbp.step({i}, {a.walk if a.online else 0});\n" for i in batch))
    t = batch[-1]
    if sql("select count(*) from jbp.client where phase between 0 and 5") == "0":
        break

ticks = sql("""select json_build_object('n', count(*), 'wall_avg', round(avg(wall_ms)::numeric, 1), 'wall_p50', round((percentile_cont(.5) within group (order by wall_ms))::numeric, 1),
        'wall_p99', round((percentile_cont(.99) within group (order by wall_ms))::numeric, 1), 'wall_max', round(max(wall_ms)::numeric, 1),
        'cpu_max', round(max(cpu_ms)::numeric, 1), 'cpu_p99', round((percentile_cont(.99) within group (order by cpu_ms))::numeric, 1), 'cpu_avg', round(avg(cpu_ms)::numeric, 1),
        'over50', count(*) filter (where wall_ms > 50), 'over100', count(*) filter (where wall_ms > 100),
        'cpu_over50', count(*) filter (where cpu_ms > 50), 'cpu_over100', count(*) filter (where cpu_ms > 100), 'max_parked', max(parked))
        from jbp.ticks""")
cl = sql("""select json_build_object('joiners', count(*), 'done', count(*) filter (where phase = 6), 'timed_out', count(*) filter (where phase = 9),
        'unfinished', count(*) filter (where phase between 0 and 5),
        'all_in_s', round((max(done_ms) - min(arrive_ms)) / 1000.0, 1),
        'queue_p50_s', round((percentile_cont(.5) within group (order by (login_ms - hello_ms)))::numeric / 1000, 1),
        'queue_p99_s', round((percentile_cont(.99) within group (order by (login_ms - hello_ms)))::numeric / 1000, 1),
        'queue_max_s', round(max(login_ms - hello_ms) / 1000.0, 1),
        'join_p50_s', round((percentile_cont(.5) within group (order by (done_ms - arrive_ms)))::numeric / 1000, 1),
        'join_max_s', round(max(done_ms - arrive_ms) / 1000.0, 1)) from jbp.client""")
gate = sql("select row_to_json(g) from net.join_gate_state g")
res = {"label": a.label, "joiners": a.joiners, "online": a.online, "budget": a.budget, "maxwait": a.maxwait, "initial": a.initial, "tick": a.tick, "ticks_run": t,
       "ticks": json.loads(ticks), "clients": json.loads(cl), "gate": json.loads(gate)}
if a.json:
    print(json.dumps(res))
else:
    T, C = res["ticks"], res["clients"]
    print(f"{a.label or 'run'} | joiners {a.joiners} online {a.online} budget {a.budget} | worst tick {T['wall_max']} ms p99 {T['wall_p99']} avg {T['wall_avg']} "
          f"| wall >50/>100 ms: {T['over50']}/{T['over100']} | CPU worst {T['cpu_max']} p99 {T['cpu_p99']} avg {T['cpu_avg']} >50/>100: {T['cpu_over50']}/{T['cpu_over100']} | done {C['done']}/{C['joiners']} timed out {C['timed_out']} | all in {C['all_in_s']} s | "
          f"queue p50/p99/max {C['queue_p50_s']}/{C['queue_p99_s']}/{C['queue_max_s']} s | max parked {T['max_parked']}")
