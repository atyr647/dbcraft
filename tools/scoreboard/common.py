"""Shared helpers for the scoreboard: paths, process CPU/RSS from /proc, machine load snapshot, RCON, small stats.  Standard library only."""
import json, os, re, socket, struct, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.environ.get("SCORE_OUT", "/tmp/scoreboard")
REPORTS = os.environ.get("DBCRAFT_REPORTS", "/home/user/atyr647/adacraft/generated/26.3/reports")
JAVA = "/usr/lib/jvm/java-25-openjdk-amd64/bin/java"
JAR = "/tmp/jar-dl/server.jar"
VANILLA_DIR = os.environ.get("SCORE_VANILLA_DIR", "/tmp/vanilla-score")
VANILLA_PORT = int(os.environ.get("SCORE_VANILLA_PORT", 25615))
RCON_PORT = int(os.environ.get("SCORE_RCON_PORT", 25625))
RCON_PW = "score"
PGDATA = os.environ.get("SCORE_PGDATA", "/tmp/dbcraft-pg-score")           # the SCORE_* variables let several runs share a machine (docs/PERF-IDLE.md)
PGPORT = int(os.environ.get("SCORE_PGPORT", 54599))
GW_PORT = int(os.environ.get("SCORE_GW_PORT", 25643))
CLK = os.sysconf("SC_CLK_TCK")
os.makedirs(OUT, exist_ok=True)


def load_snapshot():
    """Load average, CPU pressure (some, avg10) and steal, so every run is annotated with how busy the machine was."""
    d = {"load1": float(open("/proc/loadavg").read().split()[0])}
    try:
        d["cpu_pressure_avg10"] = float(re.search(r"some avg10=([\d.]+)", open("/proc/pressure/cpu").read()).group(1))
    except Exception:
        pass
    try:
        t = [int(x) for x in open("/proc/stat").readline().split()[1:]]
        d["steal_jiffies"] = t[7]
        d["busy_jiffies"] = sum(t) - t[3]
        d["total_jiffies"] = sum(t)
    except Exception:
        pass
    return d


def proc_cpu(pid):
    """(cpu seconds user+sys, rss MiB) of one process, or (0, 0)."""
    try:
        f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
        cpu = (int(f[11]) + int(f[12])) / CLK
        rss = int(f[21]) * os.sysconf("SC_PAGE_SIZE") / 1048576
        return cpu, rss
    except Exception:
        return 0.0, 0.0


def descendants(pid):
    kids = {}
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                kids.setdefault(int(open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[1]), []).append(int(p))
            except Exception:
                pass
    out, todo = [pid], [pid]
    while todo:
        for c in kids.get(todo.pop(), []):
            out.append(c)
            todo.append(c)
    return out


def tree_cpu(pid):
    """CPU seconds and RSS MiB summed over a process and all its descendants (a Postgres cluster: postmaster + all backends and workers)."""
    c = r = 0.0
    for p in descendants(pid):
        a, b = proc_cpu(p)
        c += a
        r += b
    return c, r


def vanilla_pid():
    r = subprocess.run(["pgrep", "-f", "server.jar nogui"], capture_output=True, text=True).stdout.split()
    for p in r:
        try:
            if os.readlink(f"/proc/{p}/cwd") == VANILLA_DIR:
                return int(p)
        except Exception:
            pass
    return None


def postmaster_pid():
    try:
        return int(open(f"{PGDATA}/postmaster.pid").readline())
    except Exception:
        return None


class Rcon:
    def __init__(self, port=RCON_PORT, pw=RCON_PW, timeout=300):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.id = 0
        self._cmd(3, pw)

    def _read(self, n):
        b = b""
        while len(b) < n:
            c = self.sock.recv(n - len(b))
            if not c:
                raise ConnectionError("rcon closed")
            b += c
        return b

    def _cmd(self, typ, body):
        self.id += 1
        data = struct.pack("<ii", self.id, typ) + body.encode() + b"\0\0"
        self.sock.sendall(struct.pack("<i", len(data)) + data)
        n = struct.unpack("<i", self._read(4))[0]
        resp = self._read(n)
        return resp[8:-2].decode(errors="replace")

    def cmd(self, c):
        return self._cmd(2, c)


def percentile(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def stats(xs):
    if not xs:
        return {}
    return {"n": len(xs), "mean": sum(xs) / len(xs), "p50": percentile(xs, 50), "p95": percentile(xs, 95),
            "p99": percentile(xs, 99), "p999": percentile(xs, 99.9), "max": max(xs)}
