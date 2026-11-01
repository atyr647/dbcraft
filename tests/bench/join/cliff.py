#!/usr/bin/env python3
"""Hunt for the occasional pathological storm: run the same login storm many times with auto_explain logging every statement (nested too) slower than a threshold.

usage: tests/bench/join/cliff.py DB [--joiners 500] [--runs 8] [--stop-over 60] [--min-duration 4s]
Prints the time of each run; stops at the first run slower than --stop-over seconds.  The plans of the slow statements go to the server log
(look for "duration:" and "Query Text"); `grep -A40 "plan:" <datadir>/log`.  Needs jbench loaded; PGHOST/PGPORT/PGUSER as for psql.
"""
import argparse, os, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("db"); ap.add_argument("--joiners", type=int, default=500); ap.add_argument("--runs", type=int, default=8)
ap.add_argument("--stop-over", type=float, default=60.0); ap.add_argument("--min-duration", default="4s")
a = ap.parse_args()
env = dict(os.environ, PGHOST=os.environ.get("PGHOST", "/tmp"), PGPORT=os.environ.get("PGPORT", "54466"), PGUSER=os.environ.get("PGUSER", "postgres"),
           PGOPTIONS="-c client_min_messages=warning")
pre = f"""load 'auto_explain';
set auto_explain.log_min_duration = '{a.min_duration}'; set auto_explain.log_nested_statements = on;
set auto_explain.log_analyze = on; set auto_explain.log_timing = off; set auto_explain.log_buffers = off;"""
for i in range(a.runs):
    script = pre + f"""
select jbench.reset(100000);
select 1 from jbench.run_tick(1, 1, 'W');
select 'M', ms_tick, ms_process, ms_drain from jbench.run_tick(2, {a.joiners}, 'J');
select 'S', relname, n_live_tup, n_dead_tup, coalesce(last_autoanalyze::text, '-'), coalesce(last_autovacuum::text, '-') from pg_stat_user_tables where schemaname in ('net', 'mc') and relname in ('conn', 'player', 'play_out', 'outbox') order by relname;
"""
    t0 = time.time()
    out = subprocess.run(["psql", "-X", "-q", "-At", "-F", "|", "-d", a.db], input=script, text=True, env=env, capture_output=True)
    dt = time.time() - t0
    m = [l for l in out.stdout.splitlines() if l.startswith("M|")]
    print(f"run {i + 1}: {dt:7.1f} s wall   {m[0] if m else out.stderr[:200]}", flush=True)
    for l in out.stdout.splitlines():
        if l.startswith("S|"): print("      ", l[2:])
    if dt > a.stop_over:
        print("pathological run caught; see the server log for the plans of the slow statements"); break
