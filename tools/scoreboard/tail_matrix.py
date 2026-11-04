#!/usr/bin/env python3
"""The tick tail with walking players, one setting at a time (docs/PERF-IDLE2.md "The tail of the tick"): runs tools/scoreboard/run.py pop for the Rust gateway of THIS checkout with
different values of a database setting (default: dbcraft.queue-trim-bytes, the bound above which net.drain_outbox() truncates the queues), alternating inside every repetition, and
appends the results (with the gateway's own tick log, see tick_tail.py) as JSON lines.

usage: tail_matrix.py [--n 50] [--moving 1.0] [--bound 500] [--values 8388608,1048576,67108864] [--key dbcraft.queue-trim-bytes] [--reps 2] [--hold 60] [--out FILE]
Environment: the SCORE_* variables of tools/scoreboard/dbcraft.sh (cluster, ports, output directory), DBCRAFT_REPORTS.
"""
import argparse, os, subprocess, sys, time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=50)
    ap.add_argument("--moving", type=float, default=1.0)
    ap.add_argument("--bound", type=float, default=500.0)
    ap.add_argument("--values", default="8388608,1048576,67108864")
    ap.add_argument("--key", default="dbcraft.queue-trim-bytes")
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--hold", type=float, default=60.0)
    ap.add_argument("--realistic", type=float, default=0.0)
    ap.add_argument("--tag", default="tail")
    ap.add_argument("--out", default=os.environ.get("TAIL_OUT", "/dev/shm/dbc-idle2-tail.jsonl"))
    a = ap.parse_args()
    here = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    port = os.environ.get("SCORE_PGPORT", "54599")
    vals = a.values.split(",")
    for rep in range(a.reps):
        order = vals[rep % len(vals):] + vals[:rep % len(vals)]
        for v in order:
            subprocess.run(["psql", "-X", "-q", "-h", "/tmp", "-p", port, "-U", "postgres", "dbcraft", "-c",
                            "insert into mc.server_property (key, value, default_value, note) values ('%s', '%s', '%s', 'tail experiment') on conflict (key) do update set value = excluded.value" % (a.key, v, v)], check=True)
            tag = "%s:%s:%s:%d:rep%d" % (a.tag, a.key.split(".")[-1], v, a.n, rep)
            e = dict(os.environ, SCORE_GATEWAY="rust", SCORE_TICKLOG="/dev/shm/dbc-idle2-ticklog-%s.csv" % tag.replace(":", "_"))
            cmd = [sys.executable, "tools/scoreboard/run.py", "pop", "--n", str(a.n), "--moving", str(a.moving), "--bound", str(a.bound), "--hold", str(a.hold), "--servers", "dbcraft", "--reps", "1",
                   "--tag", tag, "--quiet-wait", "0", "--out", a.out, "--realistic", str(a.realistic)]
            t0 = time.time()
            r = subprocess.run(cmd, cwd=here, env=e, capture_output=True, text=True)
            print("%s  %.0fs  %s" % (tag, time.time() - t0, (r.stdout.strip().splitlines() or [r.stderr.strip()[-300:]])[-1]), flush=True)


if __name__ == "__main__":
    main()
