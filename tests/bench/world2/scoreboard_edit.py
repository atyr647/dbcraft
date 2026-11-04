#!/usr/bin/env python3
"""The scoreboard's edit rows (docs/SCOREBOARD.md: single block edit, fill 1,000 blocks, fill 100,000 blocks) re-run on the current tree for both servers, V D V D alternated,
with nobody in range (the scoreboard's scenario) and with ONE player in range (docs/PERF-WORLD2.md).  The statements and the way they are timed are those of
tools/scoreboard/run2.py scenario_blocks: vanilla = round trip of an RCON command, dbcraft = server-side time of the SQL statement (psql \\timing).  With a player in range the dbcraft
side also times mc.broadcast_block_events() after every statement (what the tick spends on it); the vanilla side has the scripted client connected (its main thread sends the
packets in the tick after the command, a cost that cannot be separated from the RCON round trip).
usage: scoreboard_edit.py --vport 25811 --rport 25812 --db w2 --dbport 59347 [--repeat 3]
The vanilla server is a flat world (tests/bench/world2/vanilla_fill.py shows how it is started: level-type flat, view distance 10) and must be running.
"""
import argparse, json, os, re, statistics, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "e2e"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "scoreboard"))
import common as C
import mcclient as m

DIM = "minecraft:overworld"


def pct(xs, p):
    xs = sorted(xs); k = (len(xs) - 1) * p / 100.0; lo = int(k); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def psql_timed(a, stmts):
    script = "\\timing on\n" + ";\n".join(stmts) + ";\n"
    r = subprocess.run(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", str(a.dbport), "-U", "postgres", a.db], input=script, capture_output=True, text=True, timeout=3600)
    if r.returncode:
        sys.exit(r.stderr)
    return [float(x) for x in re.findall(r"^Time: ([\d.]+) ms", r.stdout, re.M)]


def psql(a, sql):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", str(a.dbport), "-U", "postgres", a.db, "-c", sql], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)


def vanilla(a, viewer):
    rc = C.Rcon(port=a.rport, pw="score")
    rc.cmd("gamerule max_block_modifications 2000000"); rc.cmd("gamerule random_tick_speed 0"); rc.cmd("forceload add -64 -64 63 63")
    cl = None
    if viewer:
        cl = m.Client("127.0.0.1", a.vport, "Prober"); cl.settle(1.0, 15.0)
    time.sleep(2)

    def times(cmds, ok):
        ts = []
        for c in cmds:
            t = time.perf_counter(); resp = rc.cmd(c); dt = (time.perf_counter() - t) * 1000.0
            if ok in resp:
                ts.append(dt)
            time.sleep(0.06 if viewer else 0)         # a real admin does not fire the next command before the tick that broadcasts the last one
        return ts
    single = times(["setblock %d -60 %d minecraft:%s" % (x % 90 - 45, z % 90 - 45, "stone" if (x + z) % 2 else "gold_block") for x, z in ((i * 7, i * 13) for i in range(300))], "Changed the block")
    f1 = times(["fill 0 -60 0 9 -51 9 minecraft:%s" % b for _ in range(8) for b in ("stone", "air")], "Successfully filled")
    f100 = times(["fill -25 -60 -25 24 -21 24 minecraft:%s" % b for _ in range(3) for b in ("stone", "air")], "Successfully filled")
    rc.cmd("forceload remove all")
    if cl:
        cl.close(); time.sleep(1)
    return {"single": single, "fill1k": f1, "fill100k": f100}


def dbcraft(a, viewer):
    psql(a, "truncate net.conn, mc.block_event, mc.play_out")
    psql(a, "select mc.pregenerate('%s', 0, 0, 4, true)" % DIM)
    if viewer:
        psql(a, "insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 0, 0)")
    bc = "select mc.broadcast_block_events()"
    out = {}
    def run(stmts):
        if not viewer:
            ts = psql_timed(a, stmts + ["truncate mc.block_event"])[:len(stmts)]
            return ts, []
        both = []
        for s in stmts:
            both += [s, bc]
        ts = psql_timed(a, both + ["truncate mc.play_out"])
        return ts[0:2 * len(stmts):2], ts[1:2 * len(stmts):2]
    stmts = ["select mc.set_block('%s', %d, -60, %d, 'minecraft:%s')" % (DIM, x % 90 - 45, z % 90 - 45, "stone" if (x + z) % 2 else "gold_block") for x, z in ((i * 7, i * 13) for i in range(2000))]
    out["single"], out["single_bcast"] = run(stmts)
    out["fill1k"], out["fill1k_bcast"] = run(["select mc.fill('%s', 0, -60, 0, 9, -51, 9, 'minecraft:%s')" % (DIM, b) for _ in range(8) for b in ("stone", "air")])
    out["fill100k"], out["fill100k_bcast"] = run(["select mc.fill('%s', -25, -60, -25, 24, -21, 24, 'minecraft:%s')" % (DIM, b) for _ in range(3) for b in ("stone", "air")])
    psql(a, "truncate net.conn, mc.block_event, mc.play_out")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vport", type=int, default=25811); ap.add_argument("--rport", type=int, default=25812)
    ap.add_argument("--db", default="w2"); ap.add_argument("--dbport", type=int, default=59347); ap.add_argument("--repeat", type=int, default=3); ap.add_argument("--out", default="")
    a = ap.parse_args()
    res = []
    for viewer in (False, True):
        for rep in range(a.repeat):
            order = ("vanilla", "dbcraft") if rep % 2 == 0 else ("dbcraft", "vanilla")
            for who in order:
                load = open("/proc/loadavg").read().split()[0]
                r = vanilla(a, viewer) if who == "vanilla" else dbcraft(a, viewer)
                row = {"server": who, "viewer": viewer, "rep": rep, "load1": load, **r}
                res.append(row)
                print("%-8s viewer=%-5s rep %d load %5s | setblock p50 %6.2f | fill 1k p50 %7.2f | fill 100k p50 %8.1f ms" % (who, viewer, rep + 1, load, pct(r["single"], 50), pct(r["fill1k"], 50), pct(r["fill100k"], 50))
                      + ((" | bcast: setblock %.2f, 1k %.2f, 100k %.1f" % (pct(r["single_bcast"], 50), pct(r["fill1k_bcast"], 50), pct(r["fill100k_bcast"], 50))) if who == "dbcraft" and viewer else ""), flush=True)
    print("--- medians over the repetitions (p50 of each repetition, then the median; range in brackets)")
    for viewer in (False, True):
        for who in ("vanilla", "dbcraft"):
            rows = [r for r in res if r["server"] == who and r["viewer"] == viewer]
            for k, label in (("single", "single block edit"), ("fill1k", "fill 1,000 blocks"), ("fill100k", "fill 100,000 blocks")):
                p = [pct(r[k], 50) for r in rows]
                extra = ""
                if who == "dbcraft" and viewer:
                    b = [pct(r[k + "_bcast"], 50) for r in rows]
                    extra = "   tick broadcast %.2f [%.2f - %.2f]" % (statistics.median(b), min(b), max(b))
                print("viewer=%-5s %-8s %-20s %8.2f ms [%.2f - %.2f]%s" % (viewer, who, label, statistics.median(p), min(p), max(p), extra))
    if a.out:
        json.dump(res, open(a.out, "w"))


main()
