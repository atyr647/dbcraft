#!/usr/bin/env python3
"""Measure what the REAL vanilla server spends per tick with N entities around one player (via RCON `tick query`).

usage: tools/entity/vanilla_load.py COWS ITEMS [--half 40] [--settle 25]
  Summons COWS cows (default AI: they wander) and ITEMS stone items (at rest on the ground, pickup disabled) at random positions within +-half blocks of (0,0), around the
  player that must be connected (tools/capture_vanilla.py --name Stay --seconds 3000 keeps one there), waits `settle` seconds and prints `tick query`.
  The server needs enable-rcon (rcon.port 25624, rcon.password entitytest) and the chunks around the origin loaded (a connected player does that).
"""
import os, random, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rcon import Rcon

cows, items = int(sys.argv[1]), int(sys.argv[2])
half = float(sys.argv[sys.argv.index("--half") + 1]) if "--half" in sys.argv else 40.0
settle = float(sys.argv[sys.argv.index("--settle") + 1]) if "--settle" in sys.argv else 25.0
r = Rcon()
random.seed(7)
r.cmd("kill @e[type=!player]")
time.sleep(1)
t0 = time.time()
for _ in range(cows):
    r.cmd(f"summon cow {random.uniform(-half, half):.2f} -60 {random.uniform(-half, half):.2f}")
for _ in range(items):
    r.cmd('summon item %.2f -59.9 %.2f {Item:{id:"minecraft:stone",count:1},PickupDelay:32767s,Motion:[0.0d,0.0d,0.0d]}' % (random.uniform(-half, half), random.uniform(-half, half)))
print(f"summoned {cows} cows and {items} items in {time.time() - t0:.1f} s; counts: {r.cmd('execute if entity @e[type=cow]')!r}, entities: {r.cmd('execute store result score x run execute if entity @e[type=!player]')!r}")
time.sleep(settle)
for i in range(3):
    print(re.sub(r"\s+", " ", r.cmd("tick query")).strip())
    time.sleep(6)
r.cmd("kill @e[type=!player]")
