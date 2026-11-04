#!/usr/bin/env python3
"""What the REAL vanilla 26.3 server spends to generate real terrain, per chunk (docs/PERF-WORLD2.md): CPU time of the whole JVM and wall time.

The server (normal world type, a fixed seed, no player) is started by the caller (the commands are in docs/PERF-WORLD2.md).  A square of N x N chunks is generated in
rectangles of at most 256 chunks (the limit of /forceload): `forceload add` puts a ticket on every chunk, which makes the server generate it to FULL status (terrain, carvers,
surface, features, light); the script waits until the corners and the centre of the rectangle are loaded and the JVM has gone quiet, and then removes the ticket.
Reported per phase:  chunks, wall seconds, CPU seconds of all JVM threads (generation workers, light engine, JIT, GC, IO worker; from /proc/PID/task/*/schedstat, ns),
ms of wall and of CPU per chunk.  Phases: "warm-up" (the first 1,024 chunks: the JIT is cold), "steady" (the rest), and "save" (save-all flush: writing the region files, which
dbcraft's per-chunk cost already contains as rows written).
usage: vanilla_gen.py --rcon 25812 --size 100 [--origin 400] [--out FILE.json]
"""
import argparse, glob, json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "scoreboard"))
import common as C


def jvm_pid():
    for p in subprocess.run(["pgrep", "-f", "server.jar nogui"], capture_output=True, text=True).stdout.split():
        try:
            if "dbc-world2-vanilla" in os.readlink(f"/proc/{p}/cwd"):
                return int(p)
        except OSError:
            pass
    sys.exit("vanilla JVM not found")


def cpu_ms(pid):
    tot = 0
    for t in glob.glob(f"/proc/{pid}/task/*/schedstat"):
        try:
            tot += int(open(t).read().split()[0])
        except (OSError, ValueError):
            pass
    return tot / 1e6


class Rc:
    """RCON with reconnect: vanilla drops an RCON connection now and then while its main thread is busy generating."""
    def __init__(self, port):
        self.port = port; self.c = None
    def cmd(self, text):
        for attempt in range(20):
            try:
                if self.c is None:
                    self.c = C.Rcon(port=self.port, pw="score", timeout=600)
                return self.c.cmd(text)
            except (ConnectionError, OSError):
                self.c = None; time.sleep(0.5)
        raise RuntimeError("rcon: " + text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rcon", type=int, default=25812); ap.add_argument("--size", type=int, default=100); ap.add_argument("--origin", type=int, default=400)
    ap.add_argument("--warm", type=int, default=1024); ap.add_argument("--out", default="")
    a = ap.parse_args()
    rc = Rc(a.rcon)
    pid = jvm_pid()
    print("load", open("/proc/loadavg").read().split()[:3], flush=True)
    rects = []                                   # (cx0, cz0, cx1, cz1) in chunks, at most 256 chunks
    for z0 in range(0, a.size, 16):
        for x0 in range(0, a.size, 16):
            rects.append((a.origin + x0, a.origin + z0, a.origin + min(x0 + 15, a.size - 1), a.origin + min(z0 + 15, a.size - 1)))
    done = 0
    phases = {"warm-up": [0, 0.0, 0.0], "steady": [0, 0.0, 0.0]}
    t_all = time.time(); c_all = cpu_ms(pid)
    for (x0, z0, x1, z1) in rects:
        n = (x1 - x0 + 1) * (z1 - z0 + 1)
        c0 = cpu_ms(pid); t0 = time.time()
        r = rc.cmd(f"forceload add {x0 * 16} {z0 * 16} {x1 * 16 + 15} {z1 * 16 + 15}")
        if "Marked" not in r:
            sys.exit("forceload: " + r)
        # wait for the corners and the centre to be loaded, then for the JVM to go quiet (generation of the neighbours' rings and the light finish behind the tickets)
        probes = [(x0, z0), (x1, z0), (x0, z1), (x1, z1), ((x0 + x1) // 2, (z0 + z1) // 2)]
        while not all(rc.cmd(f"execute if loaded {cx * 16 + 8} 0 {cz * 16 + 8}").startswith("Test passed") for cx, cz in probes):
            time.sleep(0.05)
        last = cpu_ms(pid); tl = time.time()
        while True:
            time.sleep(0.25)
            now = cpu_ms(pid)
            if now - last < 25:            # under 25 ms of CPU in 0.25 s: quiet (idle JVM about 5 ms)
                break
            last = now
        t1 = time.time(); c1 = cpu_ms(pid)
        rc.cmd(f"forceload remove {x0 * 16} {z0 * 16} {x1 * 16 + 15} {z1 * 16 + 15}")
        ph = "warm-up" if done < a.warm else "steady"
        phases[ph][0] += n; phases[ph][1] += t1 - t0 - 0.25; phases[ph][2] += c1 - c0
        done += n
        print(f"rect ({x0},{z0})-({x1},{z1}) {n} chunks  {t1 - t0:6.2f} s wall  {c1 - c0:8.0f} ms cpu   ({(c1 - c0) / n:5.2f} ms cpu per chunk)  [{ph}]", flush=True)
    time.sleep(2)
    c_s = cpu_ms(pid); t_s = time.time()
    rc.cmd("forceload remove all")
    r = rc.cmd("save-all flush")
    save = (time.time() - t_s, cpu_ms(pid) - c_s)
    out = {"chunks": done, "phases": {k: {"chunks": v[0], "wall_s": v[1], "cpu_ms": v[2], "ms_per_chunk_cpu": v[2] / max(1, v[0]), "ms_per_chunk_wall": v[1] * 1000 / max(1, v[0])} for k, v in phases.items()},
           "save": {"wall_s": save[0], "cpu_ms": save[1], "ms_per_chunk_cpu": save[1] / done}, "total_wall_s": time.time() - t_all, "total_cpu_ms": cpu_ms(pid) - c_all, "load_after": open("/proc/loadavg").read().split()[:3], "save_response": r}
    print(json.dumps(out, indent=1))
    if a.out:
        json.dump(out, open(a.out, "w"))


main()
