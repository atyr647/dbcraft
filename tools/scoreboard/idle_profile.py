#!/usr/bin/env python3
"""Where an idle server with N players spends its CPU (docs/PERF-IDLE2.md): starts dbcraft like tools/scoreboard/run.py pop (own cluster via SCORE_*), joins N idle bots, and over a
steady-state window records per-process CPU (idle_cpu.measure), the SQL tick's percentiles (mc.server_tick_log), the gateway's own counters, and -- when the cluster loads
pg_stat_statements -- the most expensive statements per call and in total.

usage: idle_profile.py --n 200 [--hold 40] [--vd 10] [--moving 0] [--top 25] [--json FILE]
Needs SCORE_GATEWAY=rust (the default of this tool) and a cluster set up by tests/e2e/setup.sh.  For the statement table start the cluster with
  -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track=all -c track_activity_query_size=2048   and `create extension pg_stat_statements` in the database.
"""
import argparse, json, os, sys, time

os.environ.setdefault("SCORE_GATEWAY", "rust")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
import idle_cpu
import run as R


def pgss_top(top):
    try:
        rows = R.dbq("select calls, round((total_exec_time + coalesce(total_plan_time, 0))::numeric, 1), round(((total_exec_time + coalesce(total_plan_time, 0)) / greatest(calls, 1))::numeric, 4), "
                     "round(coalesce(total_plan_time, 0)::numeric, 1), left(regexp_replace(query, '[[:space:]]+', ' ', 'g'), 110) "
                     "from pg_stat_statements where dbid = (select oid from pg_database where datname = 'dbcraft') order by total_exec_time + coalesce(total_plan_time, 0) desc limit %d" % top)
    except Exception:
        return None
    return [r.split(",", 4) for r in rows.splitlines() if r]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--hold", type=float, default=40.0)
    ap.add_argument("--vd", type=int, default=10)
    ap.add_argument("--moving", type=float, default=0.0)
    ap.add_argument("--spread", type=int, default=480)
    ap.add_argument("--settle", type=float, default=8.0)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    srv = R.Dbcraft("default")
    names = ["Bot%d" % i for i in range(a.n)] + ["Probe0"]
    srv.start(a.vd, a.n, names, a.spread)
    srv.pregenerate((a.spread + 15) // 16 + a.vd + 2)
    time.sleep(2.0)
    lg = R.LoadGens(srv.port, a.n, a.moving, a.vd, 20.0, 240.0, a.hold + 30, bound=0.0)
    out = {}
    try:
        ready = lg.wait_event("READY", 300)
        if len(ready) < len(lg.procs):
            raise SystemExit("load generators not ready")
        time.sleep(a.settle)
        try:
            R.dbq("select pg_stat_statements_reset()")
        except Exception:
            pass
        srv.window_begin()
        lg.go()
        gw = idle_cpu.gateway_pid()
        out["cpu"] = idle_cpu.measure(C.PGDATA, gw, a.hold)
        out["tick"] = srv.window_end()
        out["statements"] = pgss_top(a.top)
    finally:
        lg.close()
        srv.stop()
    t = out["tick"]
    print("players %d: tick mean %.2f ms p50 %.2f p99 %.2f max %.2f (SQL tick, mc.server_tick_log), %d ticks" % (a.n, t.get("mspt_mean", 0), t.get("mspt_p50", 0), t.get("mspt_p99", 0), t.get("mspt_max", 0), t.get("ticks", 0)))
    c = out["cpu"]
    print("CPU %.4f cores over %.0f s" % (c["total_cores"], c["seconds"]))
    for p in c["procs"]:
        if p["cores"] >= 0.0005:
            print("  %.4f  %6.1f ctxsw/s  %s" % (p["cores"], p["ctxsw_per_s"], p["title"]))
    if out["statements"]:
        print("top statements (calls, total ms, ms per call, of it planning, query):")
        for r in out["statements"]:
            print("  %8s %9s %8s %7s  %s" % tuple(r))
    if a.json:
        json.dump(out, open(a.json, "w"))


if __name__ == "__main__":
    main()
