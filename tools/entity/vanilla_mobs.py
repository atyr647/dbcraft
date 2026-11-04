#!/usr/bin/env python3
"""Measure the REAL vanilla 26.3 server with N awake mobs (default AI: cows wander) or resting items, with and without a viewer in range.  docs/PERF-MOBS2.md.

usage: tools/entity/vanilla_mobs.py --dir /dev/shm/mob2/van --port 25911 --rcon 25912 --out results.jsonl --reps 3 [--scenarios 500v,2000v,5000v,2000n,5000n,5000i]
  Scenario codes:  <N>v  N cows spread over +-AREA blocks around the one viewer (view distance 5: every cow tracked)      AREA = 40 (72 for 5000)
                   <N>n  N cows on the square ring 100..140 blocks from the viewer (simulated, sim distance 10; not tracked: view distance 5 = 80 blocks)
                   <N>i  N stone items at rest on the ground in the +-40 area, pickup disabled
                   0     the empty server (reference)
  Per scenario: summon over RCON (each in one tick-frozen batch is NOT used: the server runs normally), settle, then WINDOW seconds of samples of `tick query`
  (mean and p50/p95/p99 of the last 100 ticks, every 5 s) and of the CPU time of the "Server thread" and of the whole JVM (/proc, jiffies); the viewer's received packets and bytes
  per second (tools/entity/probe_client.py) are recorded too.  One JSON line per (rep, scenario) appended to --out.
The server is started from --dir (a copy of the jar, eula, properties; created if missing), JVM -Xms2G -Xmx2G, restarted for every repetition (cold JIT is part of vanilla, as in the scoreboard).
"""
import argparse, json, os, random, re, signal, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rcon import Rcon
import rcon as rconmod

ap = argparse.ArgumentParser()
ap.add_argument("--dir", default="/dev/shm/mob2/van"); ap.add_argument("--port", type=int, default=25911); ap.add_argument("--rcon", type=int, default=25912)
ap.add_argument("--jar", default=os.path.expanduser("~/.cache/dbcraft/server-26.3.jar")); ap.add_argument("--out", default="vanilla_mobs.jsonl")
ap.add_argument("--reps", type=int, default=1); ap.add_argument("--scenarios", default="500v,2000v,5000v,2000n,5000n,5000i")
ap.add_argument("--settle", type=float, default=45.0); ap.add_argument("--window", type=float, default=40.0); ap.add_argument("--tag", default="")
ap.add_argument("--after", default="", help="shell command run right after each scenario window (strict V-D alternation); {code} {rep} are substituted; run with the machine as the server left it")
ap.add_argument("--viewdist", type=int, default=5); ap.add_argument("--xmx", default="2G")
a = ap.parse_args()
rconmod.PORT = a.rcon; rconmod.PW = "mob2"
JAVA = "/usr/lib/jvm/java-25-openjdk-amd64/bin/java"
HERE = os.path.dirname(os.path.abspath(__file__))
CLK = os.sysconf("SC_CLK_TCK")
PROPS = f"""online-mode=false
server-port={a.port}
level-type=minecraft\\:flat
view-distance={a.viewdist}
simulation-distance=10
network-compression-threshold=-1
spawn-protection=0
enable-rcon=true
rcon.port={a.rcon}
rcon.password=mob2
motd=mob2
max-players=10
gamemode=creative
difficulty=peaceful
spawn-monsters=false
spawn-animals=false
spawn-npcs=false
generate-structures=false
white-list=false
player-idle-timeout=0
max-tick-time=-1
pause-when-empty-seconds=-1
sync-chunk-writes=false
"""


def start_server():
    os.makedirs(a.dir, exist_ok=True)
    if not os.path.exists(os.path.join(a.dir, "server.jar")):
        subprocess.check_call(["cp", a.jar, os.path.join(a.dir, "server.jar")])
    open(os.path.join(a.dir, "eula.txt"), "w").write("eula=true\n")
    open(os.path.join(a.dir, "server.properties"), "w").write(PROPS)
    subprocess.call(["rm", "-rf", os.path.join(a.dir, "world")])
    log = open(os.path.join(a.dir, "server.log"), "w")
    p = subprocess.Popen([JAVA, f"-Xms{a.xmx}", f"-Xmx{a.xmx}", "-jar", "server.jar", "nogui"], cwd=a.dir, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(300):
        time.sleep(1)
        if "Done (" in open(os.path.join(a.dir, "server.log")).read(): break
        if p.poll() is not None: sys.exit("vanilla exited: " + open(os.path.join(a.dir, "server.log")).read()[-500:])
    else:
        sys.exit("vanilla did not start")
    return p


def threads(pid):
    """jiffies of the server thread and of the whole process"""
    tot = srv = 0
    for t in os.listdir(f"/proc/{pid}/task"):
        try:
            st = open(f"/proc/{pid}/task/{t}/stat").read()
        except OSError:
            continue
        name = st[st.index("(") + 1:st.rindex(")")]
        f = st[st.rindex(")") + 2:].split()
        j = int(f[11]) + int(f[12])
        tot += j
        if name == "Server thread": srv += j
    return srv, tot


def tick_query(r):
    s = re.sub(r"\s+", " ", r.cmd("tick query"))
    m = re.search(r"Average time per tick: ([\d.]+) ?ms.*?P50: ([\d.]+) ?ms P95: ([\d.]+) ?ms P99: ([\d.]+) ?ms", s)
    if not m: return None
    return [float(x) for x in m.groups()]


def spawn(r, code, rnd):
    n = int(re.match(r"\d+", code).group()); kind = code[len(str(n)):] if n else ""
    if n == 0: return 0
    area = 72 if n >= 5000 else 40
    for _ in range(n):
        if kind == "n":
            while True:
                x = rnd.uniform(-140, 140); z = rnd.uniform(-140, 140)
                if 100 <= max(abs(x), abs(z)) <= 140: break
        else:
            x = rnd.uniform(-area, area); z = rnd.uniform(-area, area)
        if kind == "i":
            r.cmd('summon item %.2f -59.9 %.2f {Item:{id:"minecraft:stone",count:1},PickupDelay:32767s,Motion:[0.0d,0.0d,0.0d]}' % (x, z))
        else:
            r.cmd(f"summon cow {x:.2f} -60 {z:.2f}")
    return n


def counts(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def main():
    scen = a.scenarios.split(",")
    for rep in range(1, a.reps + 1):
        srv = start_server(); pid = srv.pid
        mark = os.path.join(a.dir, "mark.json")
        probe = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "probe_client.py"), "--port", str(a.port), "--name", "Stay", "--seconds", "100000", "--mark", mark],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(8)
        try:
            r = Rcon()
        except BaseException as ex:
            print("rep", rep, "could not connect to rcon:", ex, file=sys.stderr); continue
        for rule in ("mob_drops", "entity_drops"):          # `kill` of the previous scenario's mobs must not leave loot items (and xp) lying around: they are entities too (found: 803 extra items in the 2,000-cow scenario)
            r.cmd(f"gamerule {rule} false")
        try:
            for code in scen:
              try:
                rnd = random.Random(7)
                r.cmd("kill @e[type=!player]"); time.sleep(3)
                left = r.cmd("execute if entity @e[type=!player]")
                if "Count" in left and not left.endswith(" 0"):
                    print("WARNING entities left after kill:", left, "items:", r.cmd("execute if entity @e[type=item]"), "xp:", r.cmd("execute if entity @e[type=experience_orb]"), "cows:", r.cmd("execute if entity @e[type=cow]"), file=sys.stderr)
                    r.cmd("tp @e[type=!player] 0 -500 0"); time.sleep(2); r.cmd("kill @e[type=!player]"); time.sleep(2)
                t0 = time.time(); n = spawn(r, code, rnd); tsum = time.time() - t0
                ents = r.cmd("execute if entity @e[type=!player]")
                time.sleep(a.settle)
                s0, t0j = threads(pid); c0 = counts(mark); w0 = time.time(); samples = []
                while time.time() - w0 < a.window:
                    q = tick_query(r)
                    if q: samples.append(q)
                    time.sleep(5)
                s1, t1j = threads(pid); c1 = counts(mark); w1 = time.time()
                dt = w1 - w0
                rec = dict(server="vanilla", rep=rep, scenario=code, tag=a.tag, n=n, viewdist=a.viewdist, window_s=round(dt, 1), summon_s=round(tsum, 1),
                           entities=ents.strip(),
                           mean_ms=round(sum(x[0] for x in samples) / max(len(samples), 1), 2), p50_ms=round(sum(x[1] for x in samples) / max(len(samples), 1), 2),
                           p95_ms=round(sum(x[2] for x in samples) / max(len(samples), 1), 2), p99_ms=round(sum(x[3] for x in samples) / max(len(samples), 1), 2),
                           samples=samples, server_thread_cores=round((s1 - s0) / CLK / dt, 3), jvm_cores=round((t1j - t0j) / CLK / dt, 3),
                           load=open("/proc/loadavg").read().split()[0])
                rec["probe_alive"] = probe.poll() is None
                rec["players"] = r.cmd("list").strip()
                if c0 and c1 and c1["t"] > c0["t"]:
                    rec["viewer_pkts_per_s"] = {k: round((v[0] - c0["counts"].get(k, [0, 0])[0]) / (c1["t"] - c0["t"]), 1) for k, v in c1["counts"].items() if v[0] > c0["counts"].get(k, [0, 0])[0]}
                    rec["viewer_bytes_per_s"] = round(sum(v[1] - c0["counts"].get(k, [0, 0])[1] for k, v in c1["counts"].items()) / (c1["t"] - c0["t"]))
                print(json.dumps(rec), flush=True)
                open(a.out, "a").write(json.dumps(rec) + "\n")
                if a.after:
                    os.kill(pid, signal.SIGSTOP)           # the JVM sleeps while the other server is measured (no CPU contention from the idle-but-simulating vanilla)
                    try:
                        subprocess.call(a.after.format(code=code, rep=rep), shell=True)
                    finally:
                        os.kill(pid, signal.SIGCONT)
              except BaseException as ex:                  # a server that died (memory cgroup of a shared machine) or a stuck rcon: this repetition ends, the next one starts a fresh server
                print("rep", rep, "scenario", code, "aborted:", repr(ex), file=sys.stderr, flush=True)
                break
        finally:
            probe.terminate()
            try:
                r.cmd("stop")
            except Exception:
                pass
            try:
                srv.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(srv.pid, signal.SIGKILL)
            time.sleep(2)


main()
