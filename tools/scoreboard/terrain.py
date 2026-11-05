#!/usr/bin/env python3
"""Terrain generation per chunk, vanilla (real terrain, seed 12345, structures on) against dbcraft (`dbcraft:noise`), V D V D, the CPU of the whole server process tree per chunk
(docs/PERF-WORLD2.md section 3 method, tests/bench/world2/vanilla_gen.py and gen_cluster.py, here driven from the scoreboard's cluster and load gate).  NOT like for like:
vanilla builds caves, ores, trees and structures and its lighting; dbcraft:noise is height noise with 16 biomes and straight-down light.
usage: tools/scoreboard/cenv python3 tools/scoreboard/terrain.py [--size 64] [--reps 3] [--out FILE]     (the vanilla directory must contain 'dbc-world2-vanilla': vanilla_gen.py finds the JVM by it)
"""
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C
from run import wait_load, sh

VDIR = "/dev/shm/sb/dbc-world2-vanilla"
BENCH = os.path.join(C.REPO, "tests", "bench", "world2")
RCON = 58605
VPORT = 58606


def vanilla_start(jvm_xms="1G", jvm_xmx="2G"):
    os.makedirs(VDIR, exist_ok=True)
    subprocess.run(["rm", "-rf", os.path.join(VDIR, "world")])
    if not os.path.exists(os.path.join(VDIR, "server.jar")):
        subprocess.run(["cp", C.os.path.expanduser("~/.cache/dbcraft/server-26.3.jar"), os.path.join(VDIR, "server.jar")])
    open(os.path.join(VDIR, "eula.txt"), "w").write("eula=true\n")
    open(os.path.join(VDIR, "server.properties"), "w").write(
        "online-mode=false\nserver-port=%d\nlevel-seed=12345\nlevel-type=minecraft\\:normal\ngenerate-structures=true\nview-distance=2\nsimulation-distance=2\n"
        "enable-rcon=true\nrcon.port=%d\nrcon.password=score\nspawn-protection=0\nmax-tick-time=-1\npause-when-empty-seconds=-1\nspawn-monsters=false\nspawn-animals=false\n"
        "spawn-npcs=false\nplayer-idle-timeout=0\nsync-chunk-writes=false\n" % (VPORT, RCON))
    open(os.path.join(VDIR, "server.log"), "w").close()
    subprocess.Popen(["/usr/lib/jvm/java-25-openjdk-amd64/bin/java", "-Xms" + jvm_xms, "-Xmx" + jvm_xmx, "-jar", "server.jar", "nogui"], cwd=VDIR,
                     stdout=open(os.path.join(VDIR, "server.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(600):
        if "Done (" in open(os.path.join(VDIR, "server.log")).read():
            return
        time.sleep(0.5)
    raise RuntimeError("vanilla did not start")


def vanilla_stop():
    for p in subprocess.run(["pgrep", "-f", "server.jar nogui"], capture_output=True, text=True).stdout.split():
        try:
            if os.readlink("/proc/%s/cwd" % p) == VDIR:
                os.kill(int(p), 15)
        except OSError:
            pass
    for _ in range(120):
        alive = [p for p in subprocess.run(["pgrep", "-f", "server.jar nogui"], capture_output=True, text=True).stdout.split()
                 if os.path.exists("/proc/%s/cwd" % p) and os.readlink("/proc/%s/cwd" % p) == VDIR]
        if not alive:
            return
        time.sleep(0.5)
    for p in alive:
        os.kill(int(p), 9)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--out", default=os.environ.get("SCORE_RESULTS") or os.path.join(C.OUT, "results.jsonl"))
    a = ap.parse_args()
    for rep in range(a.reps):
        for server in ("vanilla", "dbcraft"):
            if any((lambda r: r.get("scenario") == "terrain" and r.get("rep") == rep and r.get("n") == a.size and r.get("server", "").split(":")[0] == server and "error" not in r)(json.loads(l))
                   for l in (open(a.out) if os.path.exists(a.out) else [])):
                print("terrain", server, "rep", rep, "already done: skipped", flush=True)
                continue
            waited, ok = wait_load(1.5, 900)
            load = C.load_snapshot()["load1"]
            rec = {"scenario": "terrain", "server": server if server == "vanilla" else "dbcraft:default", "n": a.size, "moving": 0, "vd": 0, "rep": rep, "tag": "terrain",
                   "started": time.time(), "load_before": {"load1": load}, "waited_for_quiet_s": waited, "quiet_reached": ok}
            tmp = os.path.join(C.OUT, "terrain_%s_%d.json" % (server, rep))
            try:
                if server == "vanilla":
                    vanilla_start()
                    try:
                        r = subprocess.run([sys.executable, os.path.join(BENCH, "vanilla_gen.py"), "--rcon", str(RCON), "--size", str(a.size), "--origin", "400", "--out", tmp],
                                           capture_output=True, text=True, timeout=3600)
                    finally:
                        vanilla_stop()
                    d = json.load(open(tmp))
                    rec["result"] = {"chunks": d["chunks"], "ms_per_chunk_cpu_steady": d["phases"]["steady"]["ms_per_chunk_cpu"], "ms_per_chunk_cpu_warmup": d["phases"]["warm-up"]["ms_per_chunk_cpu"],
                                     "ms_per_chunk_cpu_all": d["total_cpu_ms"] / d["chunks"], "ms_per_chunk_wall_steady": d["phases"]["steady"]["ms_per_chunk_wall"],
                                     "save_cpu_ms_per_chunk": d["save"]["ms_per_chunk_cpu"], "total_wall_s": d["total_wall_s"], "load_after": d["load_after"]}
                else:
                    sh(os.path.join(HERE, "dbcraft.sh"), "reset-world")
                    sh(os.path.join(C.REPO, "tools", "pg-dev.sh"), "start")
                    sh("psql", "-X", "-q", "-h", "/tmp", "-p", str(C.PGPORT), "-U", "postgres", "dbcraft", "-c", "update mc.server_property set value = 'dbcraft:noise' where key = 'dbcraft.generator'")
                    try:
                        r = subprocess.run([sys.executable, os.path.join(BENCH, "gen_cluster.py"), "--port", str(C.PGPORT), "--db", "dbcraft", "--pgdata", C.PGDATA,
                                            "--size", str(a.size), "--origin", str(400), "--out", tmp], capture_output=True, text=True, timeout=3600)
                    finally:
                        sh("psql", "-X", "-q", "-h", "/tmp", "-p", str(C.PGPORT), "-U", "postgres", "dbcraft", "-c",
                           "update mc.server_property set value = 'minecraft:flat' where key = 'dbcraft.generator'", check=False)
                        sh(os.path.join(HERE, "dbcraft.sh"), "reset-world", check=False)
                    d = json.load(open(tmp))
                    rec["result"] = {"chunks": d["chunks"], "ms_per_chunk_cpu_steady": d["total_cpu_ms_per_chunk"], "ms_per_chunk_cpu_all": d["total_cpu_ms_per_chunk"],
                                     "ms_per_chunk_wall_steady": d["ms_per_chunk_wall"], "gen_cpu_ms_per_chunk": d["ms_per_chunk_cpu"], "checkpoint_cpu_ms": d["checkpoint_cpu_ms"],
                                     "total_wall_s": d["gen_wall_s"] + d["checkpoint_wall_s"], "load_after": d["load_after"]}
            except Exception as e:
                rec["error"] = repr(e)
            with open(a.out, "a") as f:
                f.write(json.dumps(rec) + "\n")
            print("terrain", rec["server"], "rep", rep, "load %.2f" % load, rec.get("error", ""), {k: (round(v, 2) if isinstance(v, float) else v) for k, v in rec.get("result", {}).items()}, flush=True)


main()
