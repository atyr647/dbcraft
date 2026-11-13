#!/usr/bin/env python3
"""Light after edits: the REAL vanilla 26.3 server against dbcraft's light engine, chunk packet by chunk packet.

A vanilla server loads a world it generated itself (tests/light/vanilla_world.sh makes one; Mojang data, never committed), the same world is imported into a dbcraft
database (tools/world_import.py), and the same edits are applied to both: /setblock and /fill over RCON on vanilla (tick frozen, no random ticks, so only the light
engine acts), mc.set_block / mc.fill and one mc.light_step on dbcraft.  After every scenario a scripted client joins vanilla and records the chunk packets (the light
arrays are the ones vanilla's engine holds then); tests/world_import/compare_chunks.py compares them with dbcraft's mc.chunk_packet, component by component.

usage: tests/light/compare_edits.py --world /root/lt/van1/world.pristine [--work /root/lt/vedit] [--mc-port 25860 --rcon-port 25861] [--scenarios S1,S2,..]
Database: libpq environment (PGHOST/PGPORT/PGUSER/PGDATABASE) of a database the world was imported into (a scratch copy: the edits are written to it).
Chunks near the edge of the imported area are not compared (vanilla lit them with neighbours that are not in the database): --margin chunks around the probe.
"""
import argparse, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "entity"))

ap = argparse.ArgumentParser()
ap.add_argument("--world", required=True, help="a stopped vanilla world (the one that was imported)")
ap.add_argument("--work", default="/root/lt/vedit")
ap.add_argument("--mc-port", type=int, default=25860)
ap.add_argument("--rcon-port", type=int, default=25861)
ap.add_argument("--jar", default=os.path.expanduser("~/.cache/dbcraft/server-26.3.jar"))
ap.add_argument("--java", default="/usr/lib/jvm/java-25-openjdk-amd64/bin/java")
ap.add_argument("--scenarios", default="")
ap.add_argument("--keep", action="store_true", help="leave the vanilla server running")
a = ap.parse_args()
os.environ["RCON_PORT"] = str(a.rcon_port)
os.environ["RCON_PW"] = "lt-light"
import rcon

PSQL = os.environ.get("DBCRAFT_PSQL", "psql").split()
DIM = "minecraft:overworld"

# every scenario: a name and a list of edits; ("set", x, y, z, state) or ("fill", x1, y1, z1, x2, y2, z2, state).  Coordinates are over the swamp / ocean / grass land
# of the test world (seed 7041); states are full block-state names (the same text works in a command and in mc.set_block).
SLAB_TOP = "minecraft:oak_slab[type=top,waterlogged=false]"
STAIRS = "minecraft:oak_stairs[facing=east,half=bottom,shape=straight,waterlogged=false]"
LEAVES = "minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]"
SCENARIOS = [
    ("torches", [("set", 30, 65, 30, "minecraft:torch"), ("set", -20, 77, -20, "minecraft:torch"), ("set", 15, 64, 0, "minecraft:torch"), ("set", 16, 63, 0, "minecraft:torch")]),
    ("glowstone", [("set", 3, 92, 60, "minecraft:glowstone"), ("set", 5, 63, 5, "minecraft:glowstone"), ("set", -2, 63, 3, "minecraft:sea_lantern")]),
    ("shaft", [("fill", 31, 64, 31, 31, 45, 31, "minecraft:air")]),
    ("roof", [("fill", 28, 68, 28, 34, 68, 34, "minecraft:stone")]),
    ("pillar", [("fill", 25, 65, 25, 25, 80, 25, "minecraft:stone")]),
    ("pillar removed", [("fill", 25, 65, 25, 25, 80, 25, "minecraft:air")]),
    ("lava slab stairs leaves", [("set", 28, 65, 40, "minecraft:lava"), ("set", 29, 65, 40, SLAB_TOP), ("set", 27, 65, 40, STAIRS), ("set", -18, 78, -18, LEAVES)]),
    ("border torch row", [("set", 15, 64, 7, "minecraft:torch"), ("set", 16, 64, 7, "minecraft:torch"), ("set", 15, 64, 8, "minecraft:glowstone"), ("set", 31, 70, 16, "minecraft:glowstone")]),
    ("big fill", [("fill", 40, 63, 40, 70, 68, 55, "minecraft:glass")]),
]
if a.scenarios:
    want = [s.strip() for s in a.scenarios.split(",")]
    SCENARIOS = [s for s in SCENARIOS if s[0] in want]


def psql(sql):
    p = subprocess.run(PSQL + ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True)
    if p.returncode:
        sys.exit("psql: %s\n%s" % (sql[:200], p.stderr.decode()))
    return p.stdout.decode()


def vanilla_start():
    shutil.rmtree(a.work, ignore_errors=True)
    os.makedirs(a.work)
    shutil.copytree(a.world, os.path.join(a.work, "world"))
    shutil.copy(a.jar, os.path.join(a.work, "server.jar"))
    open(os.path.join(a.work, "eula.txt"), "w").write("eula=true\n")
    props = ["online-mode=false", "server-port=%d" % a.mc_port, "level-type=minecraft\\:normal", "view-distance=7", "simulation-distance=2", "network-compression-threshold=-1",
             "spawn-protection=0", "enable-rcon=true", "rcon.port=%d" % a.rcon_port, "rcon.password=lt-light", "motd=lt", "max-players=4", "gamemode=creative", "difficulty=peaceful",
             "spawn-monsters=false", "spawn-animals=false", "spawn-npcs=false", "generate-structures=true", "level-name=world", "white-list=false", "enforce-whitelist=false",
             "max-tick-time=-1", "pause-when-empty-seconds=-1"]
    open(os.path.join(a.work, "server.properties"), "w").write("\n".join(props) + "\n")
    log = open(os.path.join(a.work, "server.log"), "w")
    proc = subprocess.Popen([a.java, "-Xms1G", "-Xmx2G", "-jar", "server.jar", "nogui"], cwd=a.work, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(180):
        time.sleep(1)
        if "Done (" in open(os.path.join(a.work, "server.log")).read():
            return proc
    sys.exit("vanilla did not start")


def apply_vanilla(r, edits):
    for e in edits:
        if e[0] == "set":
            out = r.cmd("setblock %d %d %d %s" % e[1:])
        else:
            out = r.cmd("fill %d %d %d %d %d %d %s" % e[1:])
        if "Changed" not in out and "Could not set" not in out:
            print("  vanilla:", out.strip())


def apply_dbcraft(edits):
    for e in edits:
        if e[0] == "set":
            psql("select mc.set_block('%s', %d, %d, %d, '%s')" % ((DIM,) + e[1:]))
        else:
            psql("select mc.fill('%s', %d, %d, %d, %d, %d, %d, '%s')" % ((DIM,) + e[1:]))


def capture(n):
    out = os.path.join(a.work, "cap%d.jsonl" % n)
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "capture_vanilla.py"), "--port", str(a.mc_port), "--name", "Probe", "--seconds", "14", "--out", out],
                   capture_output=True)
    return out


proc = vanilla_start()
try:
    r = rcon.Rcon()
    for c in ("tick freeze", "gamerule random_tick_speed 0", "gamerule spawn_mobs false", "setworldspawn 0 100 0", "forceload add -64 -64 64 64"):
        r.cmd(c)
    time.sleep(8)                                        # the force-loaded area is generated / loaded (all chunks come from the files)
    fail = 0
    print("scenario".ljust(28), "chunks compared / light layers wrong (sky, block)")
    # the starting point: nothing edited yet
    steps = [("(no edit)", [])] + SCENARIOS
    for n, (name, edits) in enumerate(steps):
        apply_vanilla(r, edits)
        apply_dbcraft(edits)
        t0 = time.time()
        psql("select mc.light_step(0)")
        ms = (time.time() - t0) * 1000
        time.sleep(3)                                    # vanilla's light engine is asynchronous
        cap = capture(n)
        p = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tests", "world_import", "compare_chunks.py"), cap, "--strict-light", "--examples", "2"], capture_output=True)
        text = p.stdout.decode()
        line = [l for l in text.splitlines() if "light" in l.lower() or "compared" in l.lower()]
        print(name.ljust(28), "| dbcraft light step %.0f ms |" % ms, " / ".join(line[-3:]))
        if p.returncode:
            fail = 1
            print(text[-1500:])
    print("RESULT:", "FAIL" if fail else "PASS")
    sys.exit(fail)
finally:
    if not a.keep:
        try:
            r.cmd("stop")
        except Exception:
            pass
        time.sleep(3)
        proc.terminate()
