#!/usr/bin/env python3
"""Idle cost and chat latency, before against after, interleaved (docs/PERF-IDLE.md).

Runs tools/scoreboard/run.py for 0, 50 and 200 idle players (the scenarios idle0 / pop with --moving 0) against two builds of dbcraft that live in two checkouts and two PostgreSQL
clusters, alternating before/after inside every repetition so drift in the machine's load hits both, and appends one JSON line per run to --out.

usage: idle_matrix.py --before WRAPPER --after WRAPPER [--reps 3] [--sizes 0,50,200] [--configs rust:default,plpython:batched] [--hold 60] [--out FILE]
  WRAPPER is an executable that sets the environment of one build (SCORE_PGDATA, SCORE_PGPORT, SCORE_GW_PORT, SCORE_OUT, the working directory of its checkout) and execs its arguments;
  for example /tmp/idle/e (after) and /tmp/idle/eb (before) as used for docs/PERF-IDLE.md.  A config is GATEWAY:TICKMODE, the gateway being rust (gateway/target/dbcraft-gateway) or
  plpython (net.run), the tick mode default (mc.server_tick) or batched (mc.server_tick_batched).
Report: idle_report.py FILE
"""
import argparse, json, subprocess, sys, time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--sizes", default="0,50,200")
    ap.add_argument("--configs", default="rust:default,plpython:batched")
    ap.add_argument("--hold", type=float, default=60.0)
    ap.add_argument("--out", default="/tmp/idle/matrix.jsonl")
    a = ap.parse_args()
    for rep in range(a.reps):
        for cfg in a.configs.split(","):
            gw, mode = cfg.split(":")
            order = [("before", a.before), ("after", a.after)]
            if rep % 2:
                order.reverse()                      # the order alternates between repetitions
            for variant, wrapper in order:
                for n in [int(x) for x in a.sizes.split(",")]:
                    scen = "idle0" if n == 0 else "pop"
                    tag = "idle:%s:%s:%s:%d:rep%d" % (variant, gw, mode, n, rep)
                    cmd = [wrapper, "python3", "tools/scoreboard/run.py", scen, "--n", str(n), "--moving", "0", "--hold", str(a.hold), "--servers", "dbcraft", "--dbmode", mode,
                           "--reps", "1", "--tag", tag, "--quiet-wait", "0", "--out", a.out]
                    env = dict(__import__("os").environ, SCORE_GATEWAY=gw)
                    t0 = time.time()
                    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
                    print("%s  %.0fs  %s" % (tag, time.time() - t0, (r.stdout.strip().splitlines() or [r.stderr.strip()[-200:]])[-1]), flush=True)


if __name__ == "__main__":
    main()
