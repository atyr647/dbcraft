#!/usr/bin/env python3
"""Steady-state loop in 'gateway style': every step of every tick is a TOP-LEVEL statement of one psql session, like an external gateway that sends
`select mc.server_tick()` once per tick, so the backend goes idle between statements and PostgreSQL flushes its table statistics (which autovacuum needs).
The in-database procedure tune.run (and the development gateway net.run) never goes idle inside its CALL, so its statistics are not flushed (docs/TUNING.md).

usage: steady_top.py --ticks N --frac F [--skip S] [--hz 20] --csv OUT.csv      (connection from the usual PG* environment variables)
Per tick: tune.gen (the input, own transaction) / the epoch / mc.server_tick() / ibench.drain() / pg_sleep to the 20 Hz schedule.  The latency of a tick is the psql-reported
time of the server_tick and drain statements (each includes its own commit).  Writes the CSV that tune.lat is loaded from.  Standard library only."""
import argparse, subprocess, sys, tempfile, os, re

ap = argparse.ArgumentParser()
ap.add_argument("--ticks", type=int, required=True); ap.add_argument("--frac", type=float, default=1.0); ap.add_argument("--skip", type=int, default=0)
ap.add_argument("--hz", type=float, default=20.0); ap.add_argument("--csv", required=True)
a = ap.parse_args()
period = 1.0 / a.hz
total = a.ticks
lines = ["\\set ON_ERROR_STOP on", "\\pset tuples_only on",
         "select extract(epoch from clock_timestamp()) as t0 \\gset",           # the schedule's origin, as a psql variable (before timing is on: no Time line)
         "\\timing on",
         "select extract(epoch from clock_timestamp());"]                        # block 0: the same instant, printed
for i in range(1, total + 1):
    lines.append(f"select tune.gen({a.frac});")
    lines.append("select extract(epoch from clock_timestamp());")
    lines.append("select mc.server_tick();")
    lines.append("select ibench.drain();")
    lines.append(f"select pg_sleep(greatest(0, :t0 + {i * period} - extract(epoch from clock_timestamp())));")
with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
    f.write("\n".join(lines) + "\n")
    script = f.name
try:
    p = subprocess.run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-f", script], capture_output=True, text=True)
finally:
    os.unlink(script)
if p.returncode:
    sys.exit("psql failed: " + p.stderr[-800:])
# blocks of output, each terminated by a "Time: x ms" line
blocks, cur = [], []
for line in p.stdout.splitlines():
    m = re.match(r"Time: ([\d.]+) ms", line)
    if m:
        blocks.append((cur, float(m.group(1)))); cur = []
    elif line.strip() and not line.startswith("Timing is"):
        cur.append(line.strip())
# block layout: 0 = t0, 1 = the \gset statement (no output), then 5 per tick
t0 = float(blocks[0][0][0])
rows = []
base = 1
for i in range(1, total + 1):
    g, e, tk, dr, sl = blocks[base + (i - 1) * 5: base + i * 5]
    if i <= a.skip: continue
    t_start = float(e[0][0])
    cur_tick = int(tk[0][0])
    gen_ms, tick_ms, drain_ms = g[1], tk[1], dr[1]
    lat = tick_ms + drain_ms
    deadline = t0 + i * period
    late = max(0.0, (t_start + lat / 1000.0) - deadline) * 1000.0
    rows.append((len(rows) + 1, cur_tick, t_start, gen_ms, tick_ms, drain_ms, 0.0, lat, late))
with open(a.csv, "w") as f:
    for r in rows: f.write(",".join(str(x) for x in r) + "\n")
print(f"{len(rows)} ticks recorded")
