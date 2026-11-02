#!/usr/bin/env python3
"""Soak test: N scripted clients walk for a long time against a dbcraft server; every SAMPLE seconds everything that could explain a slowdown is recorded.

usage: tools/soak/soak.py --kind plpython|rust [--n 200] [--minutes 10] [--moving 1.0] [--vd 10] [--tick default|batched] [--check] [--setup]

  --setup    reset the world and pre-generate the area the walkers stay in (needed once per cluster state; the walkers stay within +-bound blocks)
  --check    evaluate the guard thresholds at the end and exit 1 when one fails (tests/soak/run.sh)

Environment: DBCRAFT_PGPORT (own cluster, default 54744, started with tools/pg-dev.sh and loaded with tests/e2e/setup.sh), DBCRAFT_SOAK_PORT (gateway, default 25671).
Standard library only.  Reuses the scoreboard's load generator (tools/scoreboard/loadgen.py), which behaves like a real client and records disconnects.
"""
import argparse, json, math, os, queue, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOADGEN = os.path.join(ROOT, "tools", "scoreboard", "loadgen.py")
SAMPLE_SQL = os.path.join(ROOT, "tools", "soak", "sample.sql")
PGPORT = os.environ.get("DBCRAFT_PGPORT", "54744")
GWPORT = int(os.environ.get("DBCRAFT_SOAK_PORT", "25671"))
PSQL = ["psql", "-X", "-q", "-At", "-F", "|", "-h", "/tmp", "-p", PGPORT, "-U", "postgres", "dbcraft"]
QUEUE_TABLES = ("net.inbox", "net.outbox", "mc.play_out", "mc.play_in", "mc.play_in_work", "net.play_inbox", "net.batch")


def psql(sql, timeout=600):
    r = subprocess.run(PSQL + ["-c", sql], capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError("psql failed: %s\n%s" % (sql[:120], r.stderr[:400]))
    return r.stdout


def psql_file(path, timeout=60):
    r = subprocess.run(PSQL + ["-f", path], capture_output=True, text=True, timeout=timeout)
    return r.stdout


def listening(port):
    import socket
    s = socket.socket()
    s.settimeout(0.3)
    try:
        s.connect(("127.0.0.1", port))
        s.close()
        return True
    except OSError:
        return False


def rss_mib(pid):
    try:
        for line in open("/proc/%d/status" % pid):
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024.0
    except OSError:
        pass
    return 0.0


def setup_world(a):
    psql("update mc.server_property set value = '%d' where key = 'view-distance'" % a.vd)
    psql("update mc.server_property set value = '10' where key = 'simulation-distance'")
    psql("update mc.server_property set value = '1000' where key = 'max-players'")
    psql("update mc.server_property set value = 'easy' where key = 'difficulty'")
    psql("update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation'")
    has = psql("select count(*) from pg_proc where proname = 'server_tick_default' and pronamespace = 'mc'::regnamespace").strip()
    if a.tick == "batched" and has == "0":
        psql("alter function mc.server_tick() rename to server_tick_default")
        psql("create function mc.server_tick() returns bigint language sql as 'select mc.server_tick_batched()'")
    elif a.tick == "default" and has != "0":
        psql("drop function mc.server_tick()")
        psql("alter function mc.server_tick_default() rename to server_tick")
    if a.setup:
        psql("truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch")
        psql("truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, "
             "mc.chunk_request, mc.chunk_wanted, mc.server_tick_log, mc.tick_log")
        psql("delete from mc.player")
        r = (a.spread + 15) // 16 + a.vd + 2
        t0 = time.time()
        psql("select mc.generate_batch('minecraft:overworld', array_agg(x), array_agg(z)) from generate_series(%d, %d) x, generate_series(%d, %d) z" % (-r, r, -r, r),
             timeout=3600)
        psql("checkpoint")
        print("pre-generated %d chunks in %.0f s" % ((2 * r + 1) ** 2, time.time() - t0), flush=True)
    psql("update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0")
    psql("update mc.generator_control set stop = false")


class Gateway:
    def __init__(self, kind, extra_env=None, janitor=False):
        self.kind, self.procs, self.extra_env, self.janitor = kind, [], extra_env or {}, janitor

    def start(self):
        if self.kind == "plpython":
            self.procs.append(subprocess.Popen(PSQL + ["-c", "call net.run(%d)" % GWPORT], stdout=open("/tmp/soak-gateway.log", "w"), stderr=subprocess.STDOUT))
        else:
            binary = os.path.join(ROOT, "gateway", "target", "dbcraft-gateway")
            if not os.path.exists(binary):
                subprocess.run([os.path.join(ROOT, "gateway", "build.sh")], check=True)
            env = dict(os.environ, DBCRAFT_GW_DATABASE_URL="host=/tmp port=%s user=postgres dbname=dbcraft" % PGPORT, DBCRAFT_GW_LISTEN="127.0.0.1:%d" % GWPORT,
                       DBCRAFT_GW_MAX_CONNECTIONS_PER_IP="0", DBCRAFT_GW_NEW_CONNECTIONS_PER_IP_PER_SEC="0", DBCRAFT_GW_LOGIN_ATTEMPTS_PER_IP_PER_MIN="0")
            env.update(self.extra_env)
            self.procs.append(subprocess.Popen([binary], env=env, stdout=open("/tmp/soak-gateway.log", "w"), stderr=subprocess.STDOUT))
        for _ in range(2):
            self.procs.append(subprocess.Popen(PSQL + ["-c", "call mc.run_generator(64, 5)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if self.janitor:
            env = dict(os.environ, PGHOST="/tmp", PGPORT=PGPORT, PGUSER="postgres", PGDATABASE="dbcraft")
            self.procs.append(subprocess.Popen(["bash", os.path.join(ROOT, "tools", "janitor.sh"), "5"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        for _ in range(150):
            if listening(GWPORT):
                return
            time.sleep(0.2)
        raise RuntimeError("gateway did not start; see /tmp/soak-gateway.log")

    def pid(self):
        return self.procs[0].pid if self.kind == "rust" else None

    def stop(self):
        try:
            psql("update mc.generator_control set stop = true")
            psql("update net.gateway_control set stop = true")
        except Exception:
            pass
        if self.kind == "rust" and self.procs:
            self.procs[0].terminate()
        if self.janitor and self.procs:
            self.procs[-1].terminate()                    # the janitor loop is the last process started
        for p in self.procs:
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                p.kill()
        psql("select pg_terminate_backend(pid) from pg_stat_activity where (query like 'call net.run%' or query like 'call mc.run_generator%') and pid <> pg_backend_pid()")


class LoadGens:
    def __init__(self, n, moving, vd, spread, bound, join_spread, hold, ready_timeout):
        self.q, self.procs = queue.Queue(), []
        k = max(1, math.ceil(n / 110))
        sizes = [n // k + (1 if i < n % k else 0) for i in range(k)]
        first, chunks = 0, (2 * (vd + 1) + 1) ** 2
        for i, sz in enumerate(sizes):
            cmd = [sys.executable, LOADGEN, "--port", str(GWPORT), "--n", str(sz), "--first", str(first), "--join-spread", str(join_spread), "--moving", str(moving),
                   "--ready-timeout", str(ready_timeout), "--hold", str(hold), "--expect-chunks", str(chunks), "--seed", str(100 + i), "--view-distance", str(vd),
                   "--bound", str(bound)]
            if i == 0:
                cmd.append("--probe")
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
            self.procs.append(p)
            threading.Thread(target=self._reader, args=(i, p), daemon=True).start()
            first += sz

    def _reader(self, i, p):
        for line in p.stdout:
            try:
                self.q.put((i, json.loads(line)))
            except ValueError:
                pass

    def wait(self, event, timeout):
        got, end = {}, time.time() + timeout
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
            p.stdin.write("GO\n")
            p.stdin.flush()

    def close(self):
        for p in self.procs:
            try:
                p.kill()
            except OSError:
                pass


def parse_sample(text):
    s = {"tbl": {}, "wait": [], "xmin": [], "cat": {}}
    for line in text.splitlines():
        f = line.split("|")
        k = f[0]
        try:
            if k == "tbl":
                s["tbl"][f[1]] = {"bytes": int(f[2]), "live": int(f[3]), "dead": int(f[4]), "hot": int(f[5]), "upd": int(f[6]), "vac": int(f[7]), "last_vac": f[8]}
            elif k == "cat":
                s["cat"][f[1]] = {"bytes": int(f[2]), "live": int(f[3]), "dead": int(f[4])}
            elif k == "wait":
                s["wait"].append("%s/%s x%s" % (f[1], f[2], f[3]))
            elif k == "xmin":
                s["xmin"].append({"pid": int(f[1]), "q": f[2], "xact_s": int(f[3]), "age": int(f[4])})
            elif k == "phases":
                s["phases"] = {"n": int(f[1]), "total": float(f[2] or 0), "process": float(f[3] or 0), "game": float(f[4] or 0), "blocks": float(f[5] or 0),
                               "chunks": float(f[6] or 0), "drain": float(f[7] or 0), "max": float(f[8] or 0), "frames_in": float(f[9] or 0), "frames_out": float(f[10] or 0)}
            elif k == "gwctl":
                s["gwctl"] = {"ticks": int(f[1]), "last_ms": float(f[2]), "max_ms": float(f[3]), "late": int(f[4]), "conns": int(f[5])}
            elif k == "gwstats":
                s["gwstats"] = {"ticks": int(f[1]), "late": int(f[2]), "avg_ms": float(f[3]), "max_ms": float(f[4]), "db_ms": float(f[5]), "conns": int(f[8]), "errors": int(f[9])}
            elif k in ("tick", "play", "locks_wait", "wal", "gwpid"):
                s[k] = int(f[1])
            elif k == "ka":
                s["ka"] = {"pending": int(f[1]), "max_age_ticks": int(f[2])}
            elif k == "act":
                s["act"] = {"n": int(f[1]), "max_xact_s": int(f[2]), "max_xmin_age": int(f[3])}
            elif k == "ckpt":
                s["ckpt"] = int(f[1]) + int(f[2])
            elif k == "rel":
                s["rel"] = {"all": int(f[1]), "temp": int(f[2])}
        except (ValueError, IndexError):
            pass
    return s


def sampler(stop, out, rows, gw, t0, interval):
    prev = None
    while not stop.wait(interval):
        try:
            s = parse_sample(psql_file(SAMPLE_SQL))
        except Exception as e:
            print("sample failed:", e, flush=True)
            continue
        now = time.time()
        pid = gw.pid() or s.get("gwpid") or 0
        s["t"], s["gw_rss_mib"] = round(now - t0, 1), round(rss_mib(pid), 1)
        if prev:
            s["ticks_per_s"] = round((s.get("tick", 0) - prev.get("tick", 0)) / max(0.001, now - prev["_now"]), 2)
            s["wal_mb_per_min"] = round((s.get("wal", 0) - prev.get("wal", 0)) / 1e6 / max(0.001, now - prev["_now"]) * 60, 1)
        s["_now"] = now
        prev = s
        rows.append(s)
        out.write(json.dumps({k: v for k, v in s.items() if k != "_now"}) + "\n")
        out.flush()
        ph, gc, gs = s.get("phases", {}), s.get("gwctl", {}), s.get("gwstats", {})
        queues = sum(s["tbl"].get(t, {}).get("bytes", 0) for t in QUEUE_TABLES) / 1e6
        print("t=%5.0fs play=%3d tick/s=%5s sqltick=%5.1f (proc %4.1f game %4.1f blk %4.1f chk %4.1f drain %4.1f) gw loop=%s late=%s rss=%6.1fMiB ka_pending=%s queues=%.1fMB dead(top)=%s" % (
            s["t"], s.get("play", -1), s.get("ticks_per_s", "-"), ph.get("total", 0), ph.get("process", 0), ph.get("game", 0), ph.get("blocks", 0), ph.get("chunks", 0),
            ph.get("drain", 0), gc.get("last_ms", gs.get("avg_ms", "-")), gc.get("late", gs.get("late", "-")), s["gw_rss_mib"], s.get("ka", {}).get("pending", "-"), queues,
            max(((t, v["dead"]) for t, v in s["tbl"].items()), key=lambda x: x[1], default=("-", 0))), flush=True)


def evaluate(rows, done, a):
    """The guard: returns a list of failure strings (empty = pass)."""
    bad = []
    steady = [r for r in rows if r.get("phases") and r.get("play", 0) >= 0.9 * a.n]
    if len(steady) >= 4:
        q = max(1, len(steady) // 4)
        first, last = steady[:q], steady[-q:]
        for label, get in (("sql tick", lambda r: r["phases"]["total"]), ("gateway loop", lambda r: r.get("gwctl", {}).get("last_ms") or r.get("gwstats", {}).get("avg_ms") or 0)):
            f, l = sum(map(get, first)) / len(first), sum(map(get, last)) / len(last)
            if f > 0 and l / max(f, 1.0) > a.max_growth and l > 10:
                bad.append("%s time grew %.1fx (%.1f -> %.1f ms) between the first and last quarter" % (label, l / max(f, 1.0), f, l))
        big = max((sum(r["tbl"].get(t, {}).get("bytes", 0) for t in QUEUE_TABLES) for r in rows), default=0) / 1e6
        if big > a.max_queue_mb:
            bad.append("queue tables reached %.0f MB (limit %d)" % (big, a.max_queue_mb))
    else:
        bad.append("too few steady-state samples (%d) to judge" % len(steady))
    failed = sum(d.get("failed", 0) for d in done.values())
    if failed > a.allow_drops:
        reasons = {}
        for d in done.values():
            for k, v in d.get("disconnect_reasons", {}).items():
                reasons[k] = reasons.get(k, 0) + v
        bad.append("%d clients dropped (allowed %d): %s; failure times (first, median, last) %s" % (failed, a.allow_drops, reasons, [d.get("failure_times_s") for d in done.values()]))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=("plpython", "rust"), default="plpython")
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--minutes", type=float, default=10)
    ap.add_argument("--moving", type=float, default=1.0)
    ap.add_argument("--vd", type=int, default=10)
    ap.add_argument("--spread", type=int, default=480)
    ap.add_argument("--bound", type=float, default=500)
    ap.add_argument("--join-spread", type=float, default=20)
    ap.add_argument("--ready-timeout", type=float, default=300)
    ap.add_argument("--tick", choices=("default", "batched"), default="default")
    ap.add_argument("--sample", type=float, default=30)
    ap.add_argument("--setup", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--max-growth", type=float, default=2.0, help="largest allowed ratio of tick time (last quarter / first quarter of the steady state)")
    ap.add_argument("--max-queue-mb", type=int, default=64)
    ap.add_argument("--allow-drops", type=int, default=0)
    ap.add_argument("--out", default="/tmp/soak-samples.jsonl")
    ap.add_argument("--gw-env", default="", help="comma separated KEY=VALUE for the rust gateway (DBCRAFT_GW_...)")
    ap.add_argument("--janitor", action="store_true", help="run tools/janitor.sh next to the gateway (what the PL/Python dev gateway needs for the tables the queue trimming does not cover)")
    a = ap.parse_args()
    extra = dict(kv.split("=", 1) for kv in a.gw_env.split(",") if kv)
    setup_world(a)
    gw = Gateway(a.kind, extra, a.janitor)
    gw.start()
    rows, stop = [], threading.Event()
    lg = LoadGens(a.n, a.moving, a.vd, a.spread, a.bound, a.join_spread, a.minutes * 60, a.ready_timeout)
    out = open(a.out, "w")
    t0 = time.time()
    th = threading.Thread(target=sampler, args=(stop, out, rows, gw, t0, a.sample), daemon=True)
    th.start()
    try:
        ready = lg.wait("READY", a.ready_timeout + 120)
        print("READY from %d of %d load generators; clients in play: %s" % (len(ready), len(lg.procs), sum(d.get("in_play", 0) for d in ready.values())), flush=True)
        if len(ready) < len(lg.procs):
            raise RuntimeError("load generators not ready")
        lg.go()
        done = lg.wait("DONE", a.minutes * 60 + 180)
    finally:
        stop.set()
        lg.close()
        gw.stop()
    bad = evaluate(rows, done, a)
    print("RESULT:", "PASS" if not bad else "FAIL")
    for b in bad:
        print("  -", b)
    if a.check and bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
