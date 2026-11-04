#!/usr/bin/env python3
"""The tail of the tick as the gateway saw it (docs/PERF-IDLE2.md): reads the file the Rust gateway writes at shutdown when `tick_log` is set (one line per tick: milliseconds since start,
the whole tick in milliseconds -- statements, drain, socket writes --, flags 1 lean / 2 late) and prints percentiles, the number of ticks over 50 and 100 ms, and the slowest ticks with their
position in the 20-tick second and the 300-tick keep-alive round (a spike that always lands on the same residue is a periodic job, one that does not is an event).

usage: tick_tail.py FILE [--last SECONDS] [--skip SECONDS] [--top 10]
  --last S   only the last S seconds of the file (the steady state at the end of a run); --skip S  drop the last S seconds (the clients leaving)
"""
import argparse


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def load(path, last=0.0, skip=0.0):
    rows = []
    for line in open(path):
        t, ms, fl = line.strip().split(",")
        rows.append((int(t), float(ms), int(fl)))
    if rows and skip:
        end = rows[-1][0] - skip * 1000
        rows = [r for r in rows if r[0] <= end]
    if rows and last:
        start = rows[-1][0] - last * 1000
        rows = [r for r in rows if r[0] >= start]
    return rows


def summary(rows):
    ms = [r[1] for r in rows]
    return {"ticks": len(ms), "mean": sum(ms) / max(1, len(ms)), "p50": pct(ms, 50), "p90": pct(ms, 90), "p99": pct(ms, 99), "p999": pct(ms, 99.9), "max": max(ms) if ms else float("nan"),
            "over50": sum(1 for x in ms if x > 50), "over100": sum(1 for x in ms if x > 100), "late": sum(1 for r in rows if r[2] & 2), "lean": sum(1 for r in rows if r[2] & 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--last", type=float, default=0.0)
    ap.add_argument("--skip", type=float, default=0.0)
    ap.add_argument("--top", type=int, default=10)
    a = ap.parse_args()
    rows = load(a.file, a.last, a.skip)
    s = summary(rows)
    print("%(ticks)d ticks, mean %(mean).2f ms, p50 %(p50).2f, p90 %(p90).2f, p99 %(p99).2f, p99.9 %(p999).2f, max %(max).2f; over 50 ms: %(over50)d, over 100 ms: %(over100)d; late %(late)d, lean %(lean)d" % s)
    print("slowest ticks (index within the file, ms, position in the second (0-19), in the keep-alive round (0-299)):")
    for i, r in sorted(enumerate(rows), key=lambda x: -x[1][1])[:a.top]:
        print("  tick %6d  %8.2f ms   %2d   %3d   t=%.1f s" % (i, r[1], i % 20, i % 300, r[0] / 1000.0))


if __name__ == "__main__":
    main()
