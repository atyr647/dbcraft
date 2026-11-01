#!/usr/bin/env python3
"""Run the whole scoreboard matrix in order, in one background job.  Results go to $SCORE_OUT/results.jsonl, progress to stdout.

usage: matrix.py [--phase modes|core|storm|all] [--reps 3] [--big]
Step 1 picks dbcraft's tick (default vs batched) on pop N=200, 20% moving, by the lower mean tick time; every later run uses the winner (recorded in
$SCORE_OUT/dbmode).  Step 2: idle, then N = 50 and 200 players idle / 20% moving / all moving.  Step 3: login storms.  --big adds N = 500.
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
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--big", action="store_true")
    a = ap.parse_args()
    mode = "default"
    if a.phase in ("modes", "all"):
        mode = pick_mode(2)
    elif os.path.exists(os.path.join(C.OUT, "dbmode")):
        mode = open(os.path.join(C.OUT, "dbmode")).read().strip()
    if a.phase in ("core", "all"):
        run("idle0", "--reps", a.reps, "--hold", 45, "--settle", 25, "--dbmode", mode, "--tag", "core")
        sizes = [50, 200] + ([500] if a.big else [])
        for n in sizes:
            for mv in (0.0, 0.2, 1.0):
                run("pop", "--n", n, "--moving", mv, "--reps", a.reps, "--hold", 45, "--dbmode", mode, "--tag", "core",
                    "--join-spread", 20 if n <= 200 else 40, "--ready-timeout", 300 if n <= 200 else 600)
    if a.phase in ("storm", "all"):
        for n in [50, 200] + ([500] if a.big else []):
            run("storm", "--n", n, "--reps", 2, "--dbmode", mode, "--tag", "storm", "--ready-timeout", 300 if n <= 200 else 600)


if __name__ == "__main__":
    main()
