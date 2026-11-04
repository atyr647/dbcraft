#!/usr/bin/env python3
"""Per-process CPU of a running dbcraft server over a window (docs/PERF-IDLE2.md): every process of the PostgreSQL cluster and the gateway, cores used, context
switches per second, and the total.  Standard library only; reads /proc, so small loads are measured as CPU seconds over a long window, not as a 'top' snapshot.

usage: idle_cpu.py [--seconds 60] [--pgdata DIR] [--gateway-pid PID | --gateway-pidfile FILE] [--json]
  --pgdata defaults to $SCORE_PGDATA; the gateway pid to the pid file $SCORE_OUT/gateway.pid written by tools/scoreboard/dbcraft.sh start.
As a module: measure(pgdata, gateway_pid, seconds) -> dict (used by idle_profile.py).
"""
import argparse, json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C


def title(pid):
    try:
        t = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
        return t[:70] if t else open("/proc/%d/comm" % pid).read().strip()
    except OSError:
        return "?"


def ctxt(pid):
    v = n = 0
    try:
        for line in open("/proc/%d/status" % pid):
            if line.startswith("voluntary_ctxt_switches"):
                v = int(line.split()[1])
            elif line.startswith("nonvoluntary_ctxt_switches"):
                n = int(line.split()[1])
    except OSError:
        pass
    return v, n


def snapshot(pids):
    return {p: (C.proc_cpu(p)[0], ctxt(p)) for p in pids}


def gateway_pid(pidfile=None):
    try:
        return int(open(pidfile or os.path.join(C.OUT, "gateway.pid")).read().split()[0])
    except (OSError, ValueError):
        return 0


def measure(pgdata, gw, seconds, between=None):
    """CPU of the cluster's processes plus the gateway over `seconds`.  `between` (optional) is called once in the middle of the window (it must not take long)."""
    pm = int(open(os.path.join(pgdata, "postmaster.pid")).readline())
    pids = C.descendants(pm) + ([gw] if gw and os.path.exists("/proc/%d" % gw) else [])
    names = {p: title(p) for p in pids}
    s0, t0 = snapshot(pids), time.time()
    if between:
        time.sleep(seconds / 2.0)
        between()
        time.sleep(max(0.0, seconds - (time.time() - t0)))
    else:
        time.sleep(seconds)
    s1, t1 = snapshot(pids), time.time()
    dt = t1 - t0
    rows = []
    for p in pids:
        if p not in s1 or (s1[p][0] == 0 and s0[p][0] == 0):
            continue
        cores = (s1[p][0] - s0[p][0]) / dt
        cs = ((s1[p][1][0] - s0[p][1][0]) + (s1[p][1][1] - s0[p][1][1])) / dt
        rows.append({"pid": p, "cores": cores, "ctxsw_per_s": cs, "title": names[p]})
    rows.sort(key=lambda r: -r["cores"])
    return {"seconds": dt, "total_cores": sum(r["cores"] for r in rows), "gateway_pid": gw, "procs": rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--pgdata", default=C.PGDATA)
    ap.add_argument("--gateway-pid", type=int, default=0)
    ap.add_argument("--gateway-pidfile", default=os.path.join(C.OUT, "gateway.pid"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    try:
        r = measure(a.pgdata, a.gateway_pid or gateway_pid(a.gateway_pidfile), a.seconds)
    except OSError:
        sys.exit("no postmaster.pid in " + a.pgdata)
    if a.json:
        print(json.dumps(r))
        return
    print("window %.1f s, total %.4f cores (gateway pid %s)" % (r["seconds"], r["total_cores"], r["gateway_pid"] or "not found"))
    for p in r["procs"]:
        if p["cores"] >= 0.0002 or p["ctxsw_per_s"] >= 1:
            print("  %.4f  %7.1f ctxsw/s  %6d  %s" % (p["cores"], p["ctxsw_per_s"], p["pid"], p["title"]))


if __name__ == "__main__":
    main()
