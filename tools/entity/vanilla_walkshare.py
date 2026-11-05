#!/usr/bin/env python3
"""How much do vanilla cows walk, by distance from the nearest player?  docs/WHY-MOBS-COST.md (the 24 % against dbcraft's 45 %).

Mob.checkDespawn (every tick, per mob) resets noActionTime to 0 only when the nearest player is closer than the category's no-despawn distance (32 blocks for creatures);
RandomStrollGoal.canUse (checkNoActionTime = true) returns false from noActionTime >= 100.  So a cow farther than 32 blocks from every player never strolls (after its first 5 seconds).
This summons NEAR cows at 8-24 blocks, MID cows at 40-70 and FAR cows at 100-130 blocks from the one connected player (all inside the simulation distance of 10 chunks, so they are ticked),
tags them, and samples their positions over RCON once a second.  A cow counts as walking in a second when it moved more than 0.5 blocks in it.
usage: tools/entity/vanilla_walkshare.py [--n 40] [--seconds 120] [--wait 30]      (the server is started in /dev/shm/why/van2, ports 25981/25982)
"""
import argparse, math, os, random, re, signal, subprocess, sys, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rcon as rconmod
from rcon import Rcon

ap = argparse.ArgumentParser()
ap.add_argument("--dir", default="/dev/shm/why/van2"); ap.add_argument("--port", type=int, default=25981); ap.add_argument("--rcon", type=int, default=25982)
ap.add_argument("--n", type=int, default=40); ap.add_argument("--seconds", type=int, default=120); ap.add_argument("--wait", type=float, default=30.0)
ap.add_argument("--series", default="", help="append the per-second displacement series (blocks) of every cow to this file, one JSON line per cow")
ap.add_argument("--jar", default=os.path.expanduser("~/.cache/dbcraft/server-26.3.jar")); ap.add_argument("--out", default="")
a = ap.parse_args()
rconmod.PORT = a.rcon; rconmod.PW = "why"
JAVA = "/usr/lib/jvm/java-25-openjdk-amd64/bin/java"
HERE = os.path.dirname(os.path.abspath(__file__))
PROPS = f"""online-mode=false
server-port={a.port}
level-type=minecraft\\:flat
view-distance=5
simulation-distance=10
network-compression-threshold=-1
spawn-protection=0
enable-rcon=true
rcon.port={a.rcon}
rcon.password=why
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
os.makedirs(a.dir, exist_ok=True)
if not os.path.exists(os.path.join(a.dir, "server.jar")): subprocess.check_call(["cp", a.jar, os.path.join(a.dir, "server.jar")])
open(os.path.join(a.dir, "eula.txt"), "w").write("eula=true\n"); open(os.path.join(a.dir, "server.properties"), "w").write(PROPS)
subprocess.call(["rm", "-rf", os.path.join(a.dir, "world")])
srv = subprocess.Popen([JAVA, "-Xms512M", "-Xmx1G", "-jar", "server.jar", "nogui"], cwd=a.dir, stdout=open(os.path.join(a.dir, "server.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
for _ in range(300):
    time.sleep(1)
    if "Done (" in open(os.path.join(a.dir, "server.log")).read(): break
probe = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "probe_client.py"), "--port", str(a.port), "--name", "Stay", "--seconds", "100000", "--mark", os.path.join(a.dir, "mark.json")],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(8)
try:
    r = Rcon()
    r.cmd("gamerule mob_drops false")
    rnd = random.Random(5)
    for tag, lo, hi in (("near", 8, 24), ("mid", 40, 70), ("far", 100, 130)):
        for i in range(a.n):
            ang = rnd.uniform(0, 2 * math.pi); d = rnd.uniform(lo, hi)
            r.cmd('summon cow %.2f -60 %.2f {Tags:["%s"]}' % (d * math.cos(ang), d * math.sin(ang), tag))
    print("summoned", r.cmd("execute if entity @e[type=cow]"), flush=True)
    time.sleep(a.wait)                          # noActionTime has run past 100 ticks for the cows that are not near a player
    def sample(tag):
        txt = r.cmd(f"execute as @e[tag={tag}] run data get entity @s Pos")
        return [tuple(float(x) for x in re.findall(r"(-?\d+\.\d+)d", line)) for line in txt.split("Cow has the following entity data:")[1:]]
    prev = {t: sample(t) for t in ("near", "mid", "far")}
    moved = {t: 0 for t in prev}; total = {t: 0 for t in prev}; series = {t: [[] for _ in prev[t]] for t in prev}
    t0 = time.time()
    for s in range(a.seconds):
        time.sleep(max(0, t0 + s + 1 - time.time()))
        for t in prev:
            cur = sample(t)
            if len(cur) == len(prev[t]):
                for i, (p, c) in enumerate(zip(prev[t], cur)):
                    total[t] += 1
                    dd = math.hypot(c[0] - p[0], c[2] - p[2]) if len(p) == 3 and len(c) == 3 else 0.0
                    series[t][i].append(round(dd, 3))
                    if dd > 0.5: moved[t] += 1
            prev[t] = cur
    res = {t: dict(cow_seconds=total[t], walking=moved[t], share=round(moved[t] / max(total[t], 1), 3)) for t in prev}
    print(json.dumps(res), flush=True)
    if a.series:
        with open(a.series, "a") as f:
            for t in series:
                for i, sr in enumerate(series[t]): f.write(json.dumps(dict(tag=t, cow=i, d=sr)) + "\n")
    if a.out: open(a.out, "a").write(json.dumps(dict(n=a.n, seconds=a.seconds, wait=a.wait, res=res)) + "\n")
finally:
    probe.terminate()
    try: Rcon().cmd("stop")
    except BaseException: pass
    try: srv.wait(timeout=60)
    except subprocess.TimeoutExpired: os.killpg(srv.pid, signal.SIGKILL)
