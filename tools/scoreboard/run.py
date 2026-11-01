#!/usr/bin/env python3
"""Scoreboard runner: the same scenario against the real vanilla 26.3 server and against dbcraft, one at a time, interleaved across repetitions
(V D V D V D) so drift in the machine's load hits both equally.  Results are appended as JSON lines to $SCORE_OUT/results.jsonl.

usage: run.py SCENARIO [--n N] [--moving F] [--vd VD] [--reps R] [--hold S] [--servers vanilla,dbcraft] [--dbmode default|batched] [--tag TAG]
scenarios: idle0 | pop | storm            (blocks, entities, chunkload, memdisk, crash, tail are in run2.py)
"""
import argparse, json, math, os, queue, re, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

TOOLS = C.HERE
LOADGEN = os.path.join(TOOLS, "loadgen.py")


def sh(*args, check=True, timeout=600):
    r = subprocess.run(list(args), capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError("%s failed: %s" % (args, (r.stdout + r.stderr)[-400:]))
    return r.stdout.strip()


def dbq(sql, timeout=120):
    return sh("psql", "-X", "-q", "-At", "-F", ",", "-h", "/tmp", "-p", str(C.PGPORT), "-U", "postgres", "dbcraft", "-c", sql, timeout=timeout)


def pss_mib(pid):
    try:
        for line in open("/proc/%d/smaps_rollup" % pid):
            if line.startswith("Pss:"):
                return int(line.split()[1]) / 1024.0
    except Exception:
        pass
    return 0.0


def tree_pss(pid):
    return sum(pss_mib(p) for p in C.descendants(pid))


def chunks_expected(vd):
    return (2 * (vd + 1) + 1) ** 2


# ---------------------------------------------------------------------------------------------------------------------------- servers
class Vanilla:
    name = "vanilla"
    port = C.VANILLA_PORT

    def start(self, vd, n, first_names=()):
        sh(os.path.join(TOOLS, "vanilla.sh"), "reset")
        self.t_start = time.time()
        sh(os.path.join(TOOLS, "vanilla.sh"), "start", str(vd))
        self.startup_s = time.time() - self.t_start
        self.rcon = C.Rcon()
        self.rcon.cmd("gamerule respawn_radius 800")      # new players spawn spread over +-800 blocks like dbcraft's seeded positions
        self.pid = C.vanilla_pid()

    def sample(self):
        """One /tick query: the server's own measure of its main loop (ms per tick) over the last 100 ticks."""
        t = self.rcon.cmd("tick query")
        m = re.search(r"Average time per tick: ([\d.]+)ms.*?P50: ([\d.]+)ms P95: ([\d.]+)ms P99: ([\d.]+)ms", t, re.S)
        return None if not m else {"avg": float(m.group(1)), "p50": float(m.group(2)), "p95": float(m.group(3)), "p99": float(m.group(4))}

    def cpu(self):
        return C.proc_cpu(self.pid)[0]

    def mem(self):
        return pss_mib(self.pid)

    def window_begin(self):
        self.samples = []

    def window_poll(self):
        s = self.sample()
        if s:
            self.samples.append(s)

    def window_end(self):
        s = self.samples
        if not s:
            return {}
        return {"mspt_mean": sum(x["avg"] for x in s) / len(s), "mspt_p50": C.percentile([x["p50"] for x in s], 50),
                "mspt_p95": C.percentile([x["p95"] for x in s], 50), "mspt_p99": C.percentile([x["p99"] for x in s], 50),
                "mspt_worst_window_p99": max(x["p99"] for x in s), "mspt_worst_window_avg": max(x["avg"] for x in s), "samples": len(s)}

    def stop(self):
        sh(os.path.join(TOOLS, "vanilla.sh"), "stop", check=False)


class Dbcraft:
    name = "dbcraft"
    port = C.GW_PORT

    def __init__(self, mode="default"):
        self.mode = mode

    def start(self, vd, n, first_names=()):
        dc = os.path.join(TOOLS, "dbcraft.sh")
        sh(dc, "stop", check=False)
        sh(dc, "tickmode", self.mode)
        sh(dc, "reset-world")
        sh(dc, "settings", str(vd))
        if n:
            self.seed_players(first_names)
        t0 = time.time()
        sh(dc, "start")
        self.startup_s = time.time() - t0
        self.pid = C.postmaster_pid()
        self.last_tick = int(dbq("select coalesce(max(tick), 0) from mc.server_tick_log") or 0)

    def seed_players(self, names):
        """Players get random positions over +-800 blocks (100 x 100 chunks), the same spread vanilla's respawn_radius gives."""
        vals = ",".join("('%s')" % n for n in names)
        dbq("insert into mc.player (uuid, name, gamemode, x, y, z, yaw, chunk_x, chunk_z) "
            "select net.offline_uuid(n), n, 1, x, gs.spawn_y, z, 0, floor(x / 16)::int, floor(z / 16)::int "
            "from (select n, random() * 1600 - 800 as x, random() * 1600 - 800 as z from (values %s) v(n)) q, mc.game_state gs "
            "on conflict (uuid) do nothing" % vals)

    def cpu(self):
        return C.tree_cpu(self.pid)[0]

    def mem(self):
        return tree_pss(self.pid)

    def window_begin(self):
        self.t0_tick = int(dbq("select coalesce(max(tick), 0) from mc.server_tick_log") or 0)
        self.t0 = time.time()

    def window_poll(self):
        pass

    def window_end(self):
        rows = dbq("select ms_total, ms_process, ms_game, ms_blocks, ms_chunks, ms_drain, players from mc.server_tick_log where tick > %d order by tick" % self.t0_tick)
        data = [[float(x) if x else 0.0 for x in r.split(",")] for r in rows.splitlines() if r]
        if not data:
            return {}
        tot = [r[0] for r in data]
        d = C.stats(tot)
        out = {"mspt_mean": d["mean"], "mspt_p50": d["p50"], "mspt_p95": d["p95"], "mspt_p99": d["p99"], "mspt_p999": d["p999"], "mspt_max": d["max"],
               "ticks": len(data), "tps": len(data) / max(1e-9, time.time() - self.t0),
               "over50": sum(1 for x in tot if x > 50), "over100": sum(1 for x in tot if x > 100)}
        for i, k in enumerate(["process", "game", "blocks", "chunks", "drain"], start=1):
            out["phase_" + k + "_mean"] = sum(r[i] for r in data) / len(data)
        try:
            g = dbq("select last_tick_ms, max_tick_ms, late_ticks from net.gateway_control").split(",")
            out["gateway_last_ms"], out["gateway_max_ms"], out["gateway_late_ticks"] = float(g[0]), float(g[1]), int(g[2])
        except Exception:
            pass
        return out

    def stop(self):
        sh(os.path.join(TOOLS, "dbcraft.sh"), "stop", check=False)


def make(server, mode):
    return Vanilla() if server == "vanilla" else Dbcraft(mode)


def wait_quiet(max_busy, wait_s):
    """Wait until the rest of the machine is quiet (CPU busy fraction below max_busy for three 5 s samples in a row), up to wait_s seconds.
    The servers under test are stopped at this point, so the busy fraction is other jobs' load.  Returns (waited_s, quiet_reached)."""
    t0 = time.time()
    good = 0
    while time.time() - t0 < wait_s:
        a = C.load_snapshot()
        time.sleep(5.0)
        b = C.load_snapshot()
        dt = b["total_jiffies"] - a["total_jiffies"]
        busy = (b["busy_jiffies"] - a["busy_jiffies"]) / dt if dt > 0 else 1.0
        good = good + 1 if busy < max_busy else 0
        if good >= 3:
            return time.time() - t0, True
    return time.time() - t0, False


# ---------------------------------------------------------------------------------------------------------------------------- load generator
class LoadGens:
    def __init__(self, port, n, moving, vd, join_spread, ready_timeout, hold, procs=None, probe=True):
        self.procs = []
        self.q = queue.Queue()
        per = 110
        k = procs or max(1, math.ceil(n / per))
        sizes = [n // k + (1 if i < n % k else 0) for i in range(k)]
        first = 0
        self.names = []
        for i, sz in enumerate(sizes):
            args = [sys.executable, LOADGEN, "--port", str(port), "--n", str(sz), "--first", str(first), "--join-spread", str(join_spread),
                    "--moving", str(moving), "--ready-timeout", str(ready_timeout), "--hold", str(hold), "--expect-chunks", str(chunks_expected(vd)),
                    "--seed", str(100 + i)]
            self.names += ["Bot%d" % j for j in range(first, first + sz)]
            if probe and i == 0:
                args.append("--probe")
                self.names.append("Probe%d" % first)
            p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
            self.procs.append(p)
            threading.Thread(target=self._reader, args=(i, p), daemon=True).start()
            first += sz

    def _reader(self, i, p):
        for line in p.stdout:
            try:
                self.q.put((i, json.loads(line)))
            except Exception:
                pass

    def wait_event(self, event, timeout):
        got = {}
        end = time.time() + timeout
        while len(got) < len(self.procs) and time.time() < end:
            try:
                i, d = self.q.get(timeout=1.0)
            except queue.Empty:
                continue
            if d.get("event") == event:
                got[i] = d
        return got

    def go(self):
        for p in self.procs:
            try:
                p.stdin.write("GO\n")
                p.stdin.flush()
            except Exception:
                pass

    def close(self):
        for p in self.procs:
            try:
                p.kill()
            except Exception:
                pass


def merge_done(done):
    """Combine the DONE records of several load generator processes."""
    out = {"clients": 0, "in_play": 0, "ready": 0, "failed": 0, "rx_bytes": 0, "join_to_play_s": [], "join_to_last_chunk_s": [], "chunks_per_client": [],
           "rtt_ms": [], "failures": {}}
    for d in done.values():
        for k in ("clients", "in_play", "ready", "failed", "rx_bytes"):
            out[k] += d.get(k, 0)
        for k in ("join_to_play_s", "join_to_last_chunk_s", "chunks_per_client", "rtt_ms"):
            out[k] += d.get(k, [])
        for f, c in d.get("failures", {}).items():
            out["failures"][f] = out["failures"].get(f, 0) + c
    return out


def client_summary(m):
    s = {"clients": m["clients"], "in_play": m["in_play"], "failed": m["failed"], "failures": m["failures"], "rx_mib": m["rx_bytes"] / 1048576.0}
    if m["rtt_ms"]:
        r = C.stats(m["rtt_ms"])
        s.update({"rtt_n": r["n"], "rtt_p50": r["p50"], "rtt_p95": r["p95"], "rtt_p99": r["p99"], "rtt_max": r["max"]})
    if m["join_to_last_chunk_s"]:
        j = C.stats(m["join_to_last_chunk_s"])
        s.update({"join_all_chunks_p50_s": j["p50"], "join_all_chunks_p95_s": j["p95"], "join_all_chunks_max_s": j["max"]})
    if m["join_to_play_s"]:
        j = C.stats(m["join_to_play_s"])
        s.update({"join_to_play_p50_s": j["p50"], "join_to_play_max_s": j["max"]})
    if m["chunks_per_client"]:
        s["chunks_per_client_median"] = C.percentile(m["chunks_per_client"], 50)
    return s


# ---------------------------------------------------------------------------------------------------------------------------- scenarios
def scenario_idle0(srv, a):
    srv.start(a.vd, 0)
    time.sleep(a.settle)
    srv.window_begin()
    c0, t0 = srv.cpu(), time.time()
    end = t0 + a.hold
    while time.time() < end:
        srv.window_poll()
        time.sleep(3.0 if srv.name == "vanilla" else 1.0)
    c1, t1 = srv.cpu(), time.time()
    r = srv.window_end()
    r.update({"cpu_cores": (c1 - c0) / (t1 - t0), "mem_mib": srv.mem(), "startup_s": srv.startup_s})
    return r


def scenario_pop(srv, a):
    first_names = ["Bot%d" % i for i in range(a.n)] + ["Probe0"]
    srv.start(a.vd, a.n, first_names)
    time.sleep(2.0)
    lg = LoadGens(srv.port, a.n, a.moving, a.vd, a.join_spread, a.ready_timeout, a.hold)
    try:
        ready = lg.wait_event("READY", a.ready_timeout + 60)
        if len(ready) < len(lg.procs):
            raise RuntimeError("load generators not ready: %d of %d" % (len(ready), len(lg.procs)))
        rs = {"ready_clients": sum(d["ready"] for d in ready.values()), "timed_out": any(d.get("timed_out") for d in ready.values()),
              "time_to_ready_s": max(d["t"] for d in ready.values())}
        time.sleep(a.settle)           # let the join burst drain before measuring steady state
        srv.window_begin()
        c0, t0 = srv.cpu(), time.time()
        lg.go()
        end = t0 + a.hold
        while time.time() < end:
            srv.window_poll()
            time.sleep(3.0 if srv.name == "vanilla" else 1.0)
        c1, t1 = srv.cpu(), time.time()
        r = srv.window_end()
        done = lg.wait_event("DONE", 60)
        r.update({"cpu_cores": (c1 - c0) / (t1 - t0), "mem_mib": srv.mem(), "startup_s": srv.startup_s})
        r.update(rs)
        r.update(client_summary(merge_done(done)))
        return r
    finally:
        lg.close()


def scenario_storm(srv, a):
    first_names = ["Bot%d" % i for i in range(a.n)] + ["Probe0"]
    srv.start(a.vd, a.n, first_names)
    time.sleep(2.0)
    srv.window_begin()
    c0, t0 = srv.cpu(), time.time()
    lg = LoadGens(srv.port, a.n, 0.0, a.vd, 1.0, a.ready_timeout, 5, probe=False)
    try:
        stop = threading.Event()

        def poller():
            while not stop.is_set():
                srv.window_poll()
                time.sleep(1.0 if srv.name == "vanilla" else 5.0)
        th = threading.Thread(target=poller, daemon=True)
        th.start()
        ready = lg.wait_event("READY", a.ready_timeout + 60)
        t1 = time.time()
        stop.set()
        r = srv.window_end()
        if len(ready) < len(lg.procs):
            raise RuntimeError("storm: load generators not ready")
        r.update({"storm_total_s": t1 - t0 - 0.0, "time_to_ready_s": max(d["t"] for d in ready.values()), "ready_clients": sum(d["ready"] for d in ready.values()),
                  "timed_out": any(d.get("timed_out") for d in ready.values()), "cpu_s_total": srv.cpu() - c0, "mem_mib": srv.mem()})
        lg.go()
        done = lg.wait_event("DONE", 60)
        r.update(client_summary(merge_done(done)))
        return r
    finally:
        lg.close()


SCENARIOS = {"idle0": scenario_idle0, "pop": scenario_pop, "storm": scenario_storm}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--n", type=int, default=50)
    ap.add_argument("--moving", type=float, default=0.0)
    ap.add_argument("--vd", type=int, default=10)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--hold", type=float, default=45.0)
    ap.add_argument("--settle", type=float, default=8.0)
    ap.add_argument("--join-spread", type=float, default=20.0)
    ap.add_argument("--ready-timeout", type=float, default=240.0)
    ap.add_argument("--servers", default="vanilla,dbcraft")
    ap.add_argument("--dbmode", default="default")
    ap.add_argument("--quiet-wait", type=float, default=600.0, help="max seconds to wait before each run for the machine to go quiet (0 = never wait)")
    ap.add_argument("--quiet-busy", type=float, default=0.30, help="CPU busy fraction below which the machine counts as quiet")
    ap.add_argument("--tag", default="")
    ap.add_argument("--out", default=os.path.join(C.OUT, "results.jsonl"))
    a = ap.parse_args()
    if a.scenario in SCENARIOS:
        fn = SCENARIOS[a.scenario]
    else:
        import run2
        fn = run2.SCENARIOS[a.scenario]
    for rep in range(a.reps):
        for server in a.servers.split(","):
            srv = make(server, a.dbmode)
            waited, quiet_ok = (0.0, True) if a.quiet_wait <= 0 else wait_quiet(a.quiet_busy, a.quiet_wait)
            snap0 = C.load_snapshot()
            t_wall = time.time()
            rec = {"scenario": a.scenario, "server": server + (":" + a.dbmode if server == "dbcraft" else ""), "n": a.n, "moving": a.moving, "vd": a.vd,
                   "rep": rep, "hold": a.hold, "tag": a.tag, "started": t_wall, "load_before": snap0, "waited_for_quiet_s": waited, "quiet_reached": quiet_ok}
            try:
                rec["result"] = fn(srv, a)
            except Exception as e:
                rec["error"] = repr(e)
            finally:
                try:
                    srv.stop()
                except Exception:
                    pass
            snap1 = C.load_snapshot()
            rec["load_after"] = snap1
            dt = snap1.get("total_jiffies", 0) - snap0.get("total_jiffies", 0)
            if dt > 0:
                rec["machine_busy_frac"] = (snap1["busy_jiffies"] - snap0["busy_jiffies"]) / dt
                rec["machine_steal_frac"] = (snap1["steal_jiffies"] - snap0["steal_jiffies"]) / dt
            rec["wall_s"] = time.time() - t_wall
            with open(a.out, "a") as f:
                f.write(json.dumps(rec) + "\n")
            r = rec.get("result", {})
            print("%-8s %-16s n=%-4d mov=%.1f rep=%d  mspt mean=%s p99=%s cpu=%s rtt_p50=%s load=%.1f %s" % (
                a.scenario, rec["server"], a.n, a.moving, rep, "%.2f" % r["mspt_mean"] if "mspt_mean" in r else "-", "%.2f" % r["mspt_p99"] if "mspt_p99" in r else "-",
                "%.2f" % r["cpu_cores"] if "cpu_cores" in r else "-", "%.0f" % r["rtt_p50"] if "rtt_p50" in r else "-", snap0["load1"], rec.get("error", "")), flush=True)


if __name__ == "__main__":
    main()
