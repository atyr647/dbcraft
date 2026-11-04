#!/usr/bin/env python3
"""What the REAL vanilla 26.3 server spends on the same edits as bench_broadcast.sql, with and without a player in range (docs/PERF-WORLD2.md).

For each scenario and repetition (stone and air alternate, so every call changes every block) it records
  * the RCON round trip of the command (the server's main thread runs the command; the round trip is the command plus waiting for the main thread),
  * the CPU time of the "Server thread" (main thread) and of the whole JVM (all threads: light engine, chunk workers, network) between just before the command and
    0.6 s after it, from /proc/PID/task/TID/schedstat (nanoseconds, no quantisation), minus the same thread's idle CPU over a window of the same length measured right
    before the scenario,
  * when a client is connected: the wall time from sending the command to the last packet of the change arriving at the client, and the packets it received.
usage: vanilla_fill.py --port 25811 --rcon 25812 [--reps 7] [--viewer yes|no|both] [--out FILE.json]
The server is started by the caller (tests/bench/world2/README or the commands in docs/PERF-WORLD2.md), flat world, `gamerule max_block_modifications` is raised here.
"""
import argparse, glob, json, os, statistics, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "e2e"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "scoreboard"))
import mcclient as m
import common as C

SCEN = [("1 block (setblock)", "set", (5, -60, 5)),
        ("10 blocks (10x1x1)", "fill", (0, -60, 0, 9, -60, 0)),
        ("48 blocks (4x4x3)", "fill", (0, -60, 0, 3, -58, 3)),
        ("1,000 blocks (10x10x10)", "fill", (0, -60, 0, 9, -51, 9)),
        ("one whole section (16x16x16)", "fill", (0, -48, 0, 15, -33, 15)),
        ("64 whole sections", "fill", (0, -64, 0, 63, -1, 63)),
        ("100,000 blocks (50x40x50, scoreboard)", "fill", (-25, -60, -25, 24, -21, 24))]


def jvm_pid(port):
    out = subprocess.run(["pgrep", "-f", "server.jar nogui"], capture_output=True, text=True).stdout.split()
    for p in out:
        try:
            cwd = os.readlink(f"/proc/{p}/cwd")
            if "dbc-world2-vanilla" in cwd:
                return int(p)
        except OSError:
            pass
    sys.exit("vanilla JVM not found")


def sched_ns(path):
    try:
        return int(open(path).read().split()[0])
    except OSError:
        return 0


class Cpu:
    def __init__(self, pid):
        self.pid = pid
        self.main = None
        for t in glob.glob(f"/proc/{pid}/task/*"):
            if open(t + "/comm").read().strip() == "Server thread":
                self.main = t
        assert self.main, "no Server thread"

    def read(self):
        tot = sum(sched_ns(t + "/schedstat") for t in glob.glob(f"/proc/{self.pid}/task/*"))
        return sched_ns(self.main + "/schedstat") / 1e6, tot / 1e6


def med(xs):
    return round(statistics.median(xs), 2)


def run(rc, cpu, client, reps, label):
    rows = []
    for name, kind, a in SCEN:
        box = a if kind == "fill" else (a[0], a[1], a[2], a[0], a[1], a[2])
        def cmd(blk):
            return f"setblock {a[0]} {a[1]} {a[2]} minecraft:{blk}" if kind == "set" else f"fill {a[0]} {a[1]} {a[2]} {a[3]} {a[4]} {a[5]} minecraft:{blk}"
        rc.cmd(cmd("air")); time.sleep(0.8)
        # idle baseline over the same window
        i0 = cpu.read(); time.sleep(0.6); i1 = cpu.read()
        idle_main, idle_all = i1[0] - i0[0], i1[1] - i0[1]
        rt, mc_, mj, pk, kb, lat = [], [], [], [], [], []
        for r in range(reps + 1):
            blk = "stone" if r % 2 == 0 else "air"
            time.sleep(0.4)
            k = client.count() if client else 0
            c0 = cpu.read(); t0 = time.time()
            resp = rc.cmd(cmd(blk))
            t1 = time.time()
            time.sleep(0.6)
            c1 = cpu.read()
            if r == 0:
                continue                              # warm-up (JIT, plans)
            rt.append((t1 - t0) * 1000)
            mc_.append(max(0.0, c1[0] - c0[0] - idle_main)); mj.append(max(0.0, c1[1] - c0[1] - idle_all))
            if client:
                ev = [e for e in client.since(k) if e["name"] in ("minecraft:section_blocks_update", "minecraft:block_update")]
                pk.append(len(ev)); kb.append(sum(len(e["body"]) for e in ev) / 1000)
                if ev:
                    lat.append((ev[-1]["t"] + client.t0 - t0) * 1000)
        rows.append({"scenario": name, "viewer": bool(client), "rcon_ms": rt, "main_cpu_ms": mc_, "jvm_cpu_ms": mj, "packets": pk, "kB": kb, "client_latency_ms": lat,
                     "idle_main_ms": idle_main, "idle_jvm_ms": idle_all, "response": resp})
        print(f"{label} | {name:40s} | rcon {med(rt):8.2f} ({min(rt):.1f}-{max(rt):.1f}) | main cpu {med(mc_):8.2f} | jvm cpu {med(mj):8.2f} | "
              + (f"packets {int(med(pk))} {med(kb)} kB, last packet at the client {med(lat) if lat else '-'} ms | " if client else "") + resp[:40], flush=True)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=25811); ap.add_argument("--rcon", type=int, default=25812); ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--viewer", default="both"); ap.add_argument("--out", default="")
    a = ap.parse_args()
    rc = C.Rcon(port=a.rcon, pw="score")
    pid = jvm_pid(a.port)
    cpu = Cpu(pid)
    print(rc.cmd("gamerule max_block_modifications 2000000"), rc.cmd("gamerule random_tick_speed 0"), "load", open("/proc/loadavg").read().split()[:3])
    print(rc.cmd("forceload add -64 -64 79 79"))        # the area must be loaded without a player (a fill refuses unloaded chunks); vanilla keeps forced chunks ticking
    out = []
    if a.viewer in ("yes", "both"):
        c = m.Client("127.0.0.1", a.port, "Prober"); c.settle(1.0, 15.0)
        out += run(rc, cpu, c, a.reps, "viewer")
        c.close(); time.sleep(1.5)
    if a.viewer in ("no", "both"):
        out += run(rc, cpu, None, a.reps, "nobody")
    if a.out:
        json.dump(out, open(a.out, "w"))


main()
