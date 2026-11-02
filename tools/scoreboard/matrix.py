#!/usr/bin/env python3
"""Run the scoreboard matrix in order, in one background job.  Results go to $SCORE_OUT/results.jsonl, progress to stdout.

usage: matrix.py [--phase modes|idle|core|storm|misc|tail|all] [--reps 2] [--big]
Phase 'modes' picks dbcraft's tick (default vs batched) on pop N=200, 20% moving, by the lower mean tick time; every later phase uses the winner
(recorded in $SCORE_OUT/dbmode).  idle: 0 players.  core: N = 50 (idle, all moving) and N = 200 (idle, 20%, all moving).  storm: login storms.
misc: block edits, chunk loading, the 10,000-chunk world with save stall and kill -9.  tail: 200 moving players for 10 minutes.
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C

RUN = os.path.join(HERE, "run.py")
RES = os.path.join(C.OUT, "results.jsonl")


def run(*args):
    cmd = [sys.executable, RUN] + [str(a) for a in args]
    print("$", " ".join(cmd[1:]), flush=True)
    subprocess.run(cmd)


def pick_mode(reps):
    for mode in ("default", "batched"):
        run("pop", "--n", 200, "--moving", 0.2, "--servers", "dbcraft", "--dbmode", mode, "--reps", reps, "--tag", "modepick", "--hold", 40)
    m = {"default": [], "batched": []}
    for line in open(RES):
        r = json.loads(line)
        if r.get("tag") == "modepick" and "result" in r and "mspt_mean" in r["result"]:
            m[r["server"].split(":")[1]].append(r["result"]["mspt_mean"])
    best = "default"
    if m["batched"] and m["default"] and sum(m["batched"]) / len(m["batched"]) < sum(m["default"]) / len(m["default"]):
        best = "batched"
    open(os.path.join(C.OUT, "dbmode"), "w").write(best)
    print("tick modes (mean ms):", {k: (sum(v) / len(v) if v else None) for k, v in m.items()}, "-> scored mode:", best, flush=True)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", default="all")
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--big", action="store_true")
    a = ap.parse_args()
    phases = ["modes", "idle", "core", "storm", "misc", "tail"] if a.phase == "all" else a.phase.split(",")
    mode = "default"
    if "modes" in phases:
        mode = pick_mode(2)
    elif os.path.exists(os.path.join(C.OUT, "dbmode")):
        mode = open(os.path.join(C.OUT, "dbmode")).read().strip()
    common = ["--dbmode", mode, "--quiet-wait", os.environ.get("SCORE_QUIET_WAIT", 90)]
    if "idle" in phases:
        run("idle0", "--reps", 3, "--hold", 45, "--settle", 25, "--tag", "core", *common)
    if "core" in phases:
        plan = [(50, 0.0), (50, 1.0), (200, 0.0), (200, 0.2), (200, 1.0)] + ([(500, 0.2)] if a.big else [])
        for n, mv in plan:
            run("pop", "--n", n, "--moving", mv, "--reps", a.reps, "--hold", 45, "--tag", "core", "--join-spread", 20 if n <= 200 else 40,
                "--ready-timeout", 300 if n <= 200 else 600, *common)
    if "storm" in phases:
        for n in [50, 200]:
            run("storm", "--n", n, "--reps", 1, "--tag", "storm", "--ready-timeout", 300, *common)
    if "misc" in phases:
        run("blocks", "--reps", a.reps, "--tag", "misc", *common)
        run("chunkload", "--vd", 10, "--reps", a.reps, "--tag", "misc", *common)
        run("world10k", "--reps", 1, "--tag", "misc", *common)
    if "tail" in phases:
        run("pop", "--n", 200, "--moving", 1.0, "--reps", 1, "--hold", 600, "--tag", "tail", "--join-spread", 20, "--ready-timeout", 300, *common)


if __name__ == "__main__":
    main()
