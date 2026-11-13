#!/usr/bin/env python3
"""The big fluid burst on the REAL vanilla server: a 40 x 40 layer of water sources (one /fill) dropped 10 blocks, 120 ticks, CPU time of the "Server thread" (and of all JVM
threads) from /proc/PID/task/*/schedstat (nanoseconds), idle baseline of the same wall time subtracted.

usage: vanilla_burst.py --port P --rcon R --pid JVMPID [--reps 3] [--size 40] [--drop 11]   (server started by tests/e2e/vanilla_start.sh; RCON password dbcraft-e2e)

A scripted client (tests/e2e/mcclient.py) stands in range so that the chunks tick.  Per repetition: idle CPU for 7 s, then the fill, then 7 s (140 ticks at 20 TPS: the burst of 120 ticks
plus the settled tail), then the layer is removed and the world is left to settle.  Prints per repetition: server-thread CPU, JVM CPU, minus idle; and the worst tick if the
server log has `[Server thread/WARN]: Can't keep up` lines it is reported (not otherwise measured: per-tick CPU needs `/tick` profiling that perturbs the run).
"""
import argparse, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "e2e"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tools", "scoreboard"))
import mcclient as m
import common as C


def threads(pid):
    out = {}
    for t in os.listdir("/proc/%d/task" % pid):
        try:
            name = open("/proc/%d/task/%s/comm" % (pid, t)).read().strip()
            ns = int(open("/proc/%d/task/%s/schedstat" % (pid, t)).read().split()[0])
        except OSError:
            continue
        out[t] = (name, ns)
    return out


def cpu(pid):
    th = threads(pid)
    server = sum(ns for n, ns in th.values() if n == "Server thread")
    return server, sum(ns for _, ns in th.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True); ap.add_argument("--rcon", type=int, required=True); ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--reps", type=int, default=3); ap.add_argument("--size", type=int, default=40); ap.add_argument("--drop", type=int, default=11)
    ap.add_argument("--wait", type=float, default=7.0)
    a = ap.parse_args()
    rc = C.Rcon(port=a.rcon, pw="dbcraft-e2e")
    rc.cmd("tick unfreeze")
    rc.cmd("gamerule random_tick_speed 0"); rc.cmd("gamerule spawn_mobs false"); rc.cmd("gamerule max_block_modifications 2000000")
    c = m.Client("127.0.0.1", a.port, "Dyn")
    rc.cmd("tp Dyn %d -60 %d" % (a.size // 2, a.size // 2 + 20))      # (on the ground at once: a survival client left in mid-air is kicked for flying after 4 s)
    c.settle(1.0, 15.0)
    y = -61 + a.drop
    time.sleep(4)                                                       # (the chunks around the new position must be loaded)
    print(rc.cmd("fill -20 -61 -20 %d -61 %d minecraft:grass_block" % (a.size + 20, a.size + 20)))
    print(rc.cmd("fill -20 -60 -20 %d -40 %d minecraft:air" % (a.size + 20, a.size + 20)))
    time.sleep(3)
    res = []
    for r in range(a.reps):
        s0, j0 = cpu(a.pid); time.sleep(a.wait); s1, j1 = cpu(a.pid)
        idle_s, idle_j = s1 - s0, j1 - j0
        s0, j0 = cpu(a.pid)
        reply = rc.cmd("fill 0 %d 0 %d %d %d minecraft:water" % (y, a.size - 1, y, a.size - 1))
        if "Successfully" not in reply: print("FILL:", reply)
        time.sleep(a.wait)
        s1, j1 = cpu(a.pid)
        bs, bj = s1 - s0 - idle_s, j1 - j0 - idle_j
        res.append((bs / 1e9, bj / 1e9, idle_s / 1e9, idle_j / 1e9))
        print("rep %d: server thread %.3f s (idle %.3f over the same time), JVM %.3f s (idle %.3f): net server thread %.3f s, net JVM %.3f s" % (r, (bs + idle_s) / 1e9, idle_s / 1e9, (bj + idle_j) / 1e9, idle_j / 1e9, bs / 1e9, bj / 1e9))
        rc.cmd("fill -20 -60 -20 %d -40 %d minecraft:air" % (a.size + 20, a.size + 20)); time.sleep(a.wait)
    c.close()
    print("net server thread CPU per burst (s): %s" % ", ".join("%.3f" % x[0] for x in res))
    print("net JVM CPU per burst (s):           %s" % ", ".join("%.3f" % x[1] for x in res))


main()
