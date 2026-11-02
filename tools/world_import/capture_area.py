#!/usr/bin/env python3
"""Record the chunk packets a REAL vanilla server (the one started by vanilla_world.sh) sends for several places of its world.

usage: tools/world_import/capture_area.py OUT.jsonl X,Z [X,Z ...]      (block coordinates; the probe flies at y=200)
Runs tools/capture_vanilla.py (a minimal client that answers keep-alive, teleport and chunk batches) against port 25618 and, while it is connected,
teleports it with RCON to each place, one after the other, waiting for the chunks to arrive.  The capture holds raw packet bytes (compression is off in
vanilla_world.sh's server.properties).  Mojang data: keep the output outside git.
"""
import os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "entity"))
os.environ.setdefault("RCON_PORT", "25718")
os.environ.setdefault("RCON_PW", "importtest")
import rcon

out = sys.argv[1]
places = [tuple(int(v) for v in a.split(",")) for a in sys.argv[2:]]
per = 14.0                                                        # seconds per place: a 17 x 17 chunk square is sent in a few batches
total = 40 + per * len(places)
p = subprocess.Popen([sys.executable, os.path.join(ROOT, "tools", "capture_vanilla.py"), "--port", "25618", "--name", "Probe", "--seconds", str(total), "--out", out],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
r = rcon.Rcon()
for _ in range(60):                                               # wait until the probe is really in the game
    if "Probe" in r.cmd("list"):
        break
    time.sleep(1)
print(r.cmd("tick freeze").strip(), flush=True)                   # no block, fluid or random ticks from now on: what vanilla sends is what is on disk
time.sleep(2)
for x, z in places:
    print(r.cmd("tp Probe %d 200 %d" % (x, z)).strip(), flush=True)
    time.sleep(per)
print(r.cmd("gamemode creative Probe").strip())
p.wait()
print(p.stdout.read().decode().splitlines()[0])
