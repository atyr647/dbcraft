#!/usr/bin/env python3
"""The dbcraft side of scoreboard scenario 6 (fills), alone, against any database: the same statements as run2.scenario_blocks, timed the same way (server-side time of each
statement in one psql session with \\timing on), without starting the servers.  Use it to re-measure the fill rows after a change to the world code.

usage: tools/scoreboard/fill_dbcraft.py [--db dbcraft] [--host /tmp] [--port 54329] [--user postgres] [--repeat 3]
Prints per repetition: fill 1,000 blocks (16 calls) and fill 100,000 blocks (6 calls): p50, min, max in ms, then the median over repetitions.
The vanilla side (RCON `fill` round trips: 9.98 ms and 201 ms in docs/SCOREBOARD.md) is not run here.
"""
import argparse, os, re, subprocess, sys

DIM = "minecraft:overworld"


def psql_timed(a, stmts):
    script = "\\timing on\n" + ";\n".join(stmts) + ";\n"
    r = subprocess.run(["psql", "-X", "-q", "-At", "-h", a.host, "-p", str(a.port), "-U", a.user, a.db], input=script, capture_output=True, text=True, timeout=3600)
    if r.returncode:
        sys.exit(r.stderr)
    return [float(m) for m in re.findall(r"^Time: ([\d.]+) ms", r.stdout, re.M)]


def pct(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="dbcraft"); ap.add_argument("--host", default="/tmp"); ap.add_argument("--port", type=int, default=int(os.environ.get("DBCRAFT_PGPORT", "54329")))
    ap.add_argument("--user", default="postgres"); ap.add_argument("--repeat", type=int, default=3)
    a = ap.parse_args()
    res1, res100 = [], []
    for rep in range(a.repeat):
        psql_timed(a, ["select mc.pregenerate('%s', 0, 0, 4, true)" % DIM])
        f1 = psql_timed(a, ["select mc.fill('%s', 0, -60, 0, 9, -51, 9, 'minecraft:%s')" % (DIM, b) for _ in range(8) for b in ("stone", "air")])
        f100 = psql_timed(a, ["select mc.fill('%s', -25, -60, -25, 24, -21, 24, 'minecraft:%s')" % (DIM, b) for _ in range(3) for b in ("stone", "air")])
        psql_timed(a, ["truncate mc.block_event"])
        res1.append((pct(f1, 50), min(f1), max(f1))); res100.append((pct(f100, 50), min(f100), max(f100)))
        print("repetition %d: fill 1,000 blocks p50 %.2f ms (%.2f - %.2f, %d calls)   fill 100,000 blocks p50 %.1f ms (%.1f - %.1f, %d calls)" %
              (rep + 1, *res1[-1], len(f1), *res100[-1], len(f100)))
    print("median of the repetitions: fill 1,000 blocks %.2f ms, fill 100,000 blocks %.1f ms" % (pct([r[0] for r in res1], 50), pct([r[0] for r in res100], 50)))


main()
