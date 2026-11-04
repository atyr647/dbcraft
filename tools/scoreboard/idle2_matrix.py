#!/usr/bin/env python3
"""The idle matrix of docs/PERF-IDLE2.md: vanilla against two builds of dbcraft (before = the commit this work started from, after = this branch), all with the Rust gateway,
0 / 50 / 200 idle players, alternating inside every repetition (the order rotates, so no build is always first), results appended as JSON lines.

usage: idle2_matrix.py --before DIR --after DIR [--reps 3] [--sizes 0,50,200] [--hold 60] [--out FILE] [--realistic R] [--moving F] [--servers vanilla,before,after]
  DIR are two checkouts (the 'before' one may be a `git archive` of the starting commit with this tools/scoreboard copied over it); each has its own cluster, gateway port and output
  directory given by the SCORE_* variables below (defaults are the ones used for the document).  The vanilla server runs from this checkout's tools/scoreboard/vanilla.sh.
Environment: IDLE2_BEFORE_ENV / IDLE2_AFTER_ENV / IDLE2_VANILLA_ENV = "K=V K=V ..." extra variables per server (cluster directory and ports).
"""
import argparse, json, os, subprocess, sys, time


def envs(s):
    return dict(kv.split("=", 1) for kv in s.split() if "=" in kv)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", default=os.environ.get("IDLE2_BEFORE", ""), help="default: $IDLE2_BEFORE")
    ap.add_argument("--after", default=".")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--sizes", default="0,50,200")
    ap.add_argument("--hold", type=float, default=60.0)
    ap.add_argument("--out", default=os.environ.get("IDLE2_OUT", "/dev/shm/dbc-idle2-matrix.jsonl"))
    ap.add_argument("--servers", default="vanilla,before,after")
    ap.add_argument("--realistic", type=float, default=0.0)
    ap.add_argument("--moving", type=float, default=0.0)
    ap.add_argument("--tag", default="idle2")
    a = ap.parse_args()
    here = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    base = {"SCORE_GATEWAY": "rust", "DBCRAFT_REPORTS": os.environ.get("DBCRAFT_REPORTS", "/root/.cache/dbcraft/reports"),
            "SCORE_VANILLA_DIR": "/dev/shm/dbc-idle2-vanilla", "SCORE_VANILLA_PORT": "59733", "SCORE_RCON_PORT": "59734"}
    cfg = {
        "vanilla": (here, dict(base, SCORE_OUT="/dev/shm/dbc-idle2-out-v", **envs(os.environ.get("IDLE2_VANILLA_ENV", ""))), "vanilla"),
        "before": (a.before, dict(base, SCORE_PGDATA="/dev/shm/dbc-idle2-pg-before", SCORE_PGPORT="59741", SCORE_GW_PORT="59742", SCORE_OUT="/dev/shm/dbc-idle2-out-before",
                                  SCORE_PSQL_GENERATORS="1", **envs(os.environ.get("IDLE2_BEFORE_ENV", ""))), "dbcraft"),
        "after": (a.after, dict(base, SCORE_PGDATA="/dev/shm/dbc-idle2-pg", SCORE_PGPORT="59731", SCORE_GW_PORT="59732", SCORE_OUT="/dev/shm/dbc-idle2-out",
                                **envs(os.environ.get("IDLE2_AFTER_ENV", ""))), "dbcraft"),
    }
    names = a.servers.split(",")
    sizes = [int(x) for x in a.sizes.split(",")]
    for rep in range(a.reps):
        order = names[rep % len(names):] + names[:rep % len(names)]       # rotate: every server is first once in every len(names) repetitions
        for n in sizes:
            for name in order:
                cwd, env, kind = cfg[name]
                scen = "idle0" if n == 0 else "pop"
                tag = "%s:%s:%d:rep%d" % (a.tag, name, n, rep)
                e = dict(os.environ, **env)
                if name == "after":
                    e["SCORE_TICKLOG"] = "/dev/shm/dbc-idle2-ticklog-%s.csv" % tag.replace(":", "_")
                cmd = [sys.executable, "tools/scoreboard/run.py", scen, "--n", str(n), "--moving", str(a.moving), "--hold", str(a.hold), "--servers", kind, "--reps", "1", "--tag", tag,
                       "--quiet-wait", "0", "--out", a.out, "--realistic", str(a.realistic)]
                t0 = time.time()
                r = subprocess.run(cmd, cwd=cwd, env=e, capture_output=True, text=True)
                last = (r.stdout.strip().splitlines() or [r.stderr.strip()[-300:]])[-1]
                if kind == "dbcraft":                      # the gateway's own log (its shutdown line has the lean ticks and what became of every chat frame): one file per cell
                    try:
                        import shutil
                        shutil.copy(os.path.join(env["SCORE_OUT"], "gateway.log"), "/dev/shm/dbc-idle2-gwlog-%s.log" % tag.replace(":", "_"))
                    except OSError:
                        pass
                print("%s  %.0fs  %s" % (tag, time.time() - t0, last), flush=True)


if __name__ == "__main__":
    main()
