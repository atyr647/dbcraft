#!/usr/bin/env python3
"""Sound scenarios: what the server tells other players (and the player) to hear.  Two scripted clients, an operator "Surv" (the actor) and "Obs" (the observer),
in survival.  Run it against the REAL vanilla server to record, and against a dbcraft database to compare (tests/e2e/compare_sound.py).  Everything each client
receives is recorded byte for byte; `mark`s name the steps.  The scenarios of survival_probe.py (fall, kill, void, eat) are compared for their sounds too.

usage: tests/e2e/sound_probe.py SCENARIO [--host 127.0.0.1] [--port 25761] [--out /tmp/dbcraft-e2e-sound/vanilla]
  SCENARIO  place   Surv places a block of each of six sound types (stone, planks, glass, sand, wool, dirt) one after another next to him; Obs watches
            dig     Surv digs the dirt and the wool block he placed (survival: the break needs its time; the server decides on the stop-destroy packet), Obs watches
            chest   Surv places a chest, opens it, closes it; Obs watches
The server must run in survival, normal difficulty, a flat world with the surface at y = -61 (the floor the players stand on is y = -61), no mobs, "Surv" an
operator (OPS=Surv,Obs tests/e2e/vanilla_start.sh).  Writes <out>_<scenario>_surv.jsonl and <out>_<scenario>_obs.jsonl.
"""
import argparse, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("scenario")
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25761)
ap.add_argument("--out", default="/tmp/dbcraft-e2e-sound/vanilla")
ap.add_argument("--name", default="Surv"); ap.add_argument("--observer", default="Obs")
ap.add_argument("--dbcraft", action="store_true", help="clear the working area with psql (PG* variables) instead of /fill (dbcraft has no /fill command)")
a = ap.parse_args()
os.makedirs(os.path.dirname(a.out), exist_ok=True)

def cmd(c, text): c.send("minecraft:chat_command", m.string(text))
def tick(c, n=1):
    for _ in range(n):
        c.send("minecraft:client_tick_end"); c.send("minecraft:move_player_status_only", b"\x01"); time.sleep(0.05)
def action(act, x, y, z, face, seq): return m.varint(act) + m.position(x, y, z) + bytes([face]) + m.varint(seq)
def use_on(x, y, z, face, seq): return m.varint(0) + m.position(x, y, z) + m.varint(face) + struct.pack(">fff", 0.5, 1.0, 0.5) + b"\x00\x00" + m.varint(seq)
def clear_area():
    if a.dbcraft:
        import subprocess
        subprocess.run(["psql", "-X", "-q", "-At", "-c", "select mc.fill('minecraft:overworld', -2, -60, -2, 9, -57, 9, 'minecraft:air'), mc.fill('minecraft:overworld', -2, -61, -2, 9, -61, 9, 'minecraft:grass_block[snowy=false]')"], check=True, capture_output=True)
    else:
        cmd(s, "fill -2 -60 -2 9 -57 9 minecraft:air"); cmd(s, "fill -2 -61 -2 9 -61 9 minecraft:grass_block")      # (the grass under a placed block turns to dirt in a world that lives on)
    time.sleep(0.4)
def select(c, slot): c.send("minecraft:set_carried_item", struct.pack(">h", slot))

s = m.Client(a.host, a.port, a.name); o = m.Client(a.host, a.port, a.observer)
s.settle(1.0, 20.0); o.settle(1.0, 15.0)
for c in (s, o):                           # a player that quit dead comes back dead: get up (ignored by the server when alive)
    c.send("minecraft:client_command", m.varint(0)); c.settle(0.5, 3.0)
for nm in (a.name, a.observer): cmd(s, "gamemode survival " + nm)       # a vanilla world keeps the game mode of the last probe
s.settle(0.5, 3.0); o.settle(0.5, 3.0)
clear_area(); s.settle(0.5, 3.0); o.settle(0.5, 3.0)
# a known place: both next to each other at the spawn, clean inventory, full health
cmd(s, "tp %s 0.5 -60 0.5" % a.name); cmd(s, "tp %s 0.5 -60 3.5" % a.observer); cmd(s, "clear %s" % a.name); s.settle(0.5, 3.0); o.settle(0.5, 3.0)
tick(s, 6)
def both(label): s.mark(label); o.mark(label)
def quiet(q=0.5, t=4.0): s.settle(q, t); o.settle(q, t)
seq = [0]
def sq(): seq[0] += 1; return seq[0]

if a.scenario == "place":
    items = ["minecraft:stone", "minecraft:oak_planks", "minecraft:glass", "minecraft:sand", "minecraft:white_wool", "minecraft:dirt"]
    both("give")
    for it in items: cmd(s, "give %s %s 4" % (a.name, it))
    quiet(1.0); tick(s, 3)
    for i, it in enumerate(items):
        both("place " + it); select(s, i); tick(s, 2)
        s.send("minecraft:use_item_on", use_on(i + 1, -61, 0, 1, sq())); quiet(0.6)
    both("end")
elif a.scenario == "dig":
    if a.dbcraft:
        import subprocess
        subprocess.run(["psql", "-X", "-q", "-At", "-c", "select mc.set_block('minecraft:overworld', 1, -60, 0, 'minecraft:dirt'), mc.set_block('minecraft:overworld', 2, -60, 0, 'minecraft:white_wool'), mc.set_block('minecraft:overworld', 3, -60, 0, 'minecraft:oak_planks')"], check=True, capture_output=True)
    else:
        cmd(s, "setblock 1 -60 0 minecraft:dirt"); cmd(s, "setblock 2 -60 0 minecraft:white_wool"); cmd(s, "setblock 3 -60 0 minecraft:oak_planks")
    quiet(1.0); tick(s, 3)
    for (x, ticks, nm) in ((1, 14, "dirt"), (2, 22, "wool"), (3, 46, "planks")):
        both("dig " + nm)
        s.send("minecraft:player_action", action(0, x, -60, 0, 1, sq()))
        for _ in range(ticks): tick(s)
        s.send("minecraft:player_action", action(3, x, -60, 0, 1, sq())); quiet(0.6)
    both("end")
elif a.scenario == "chest":
    both("give"); cmd(s, "give %s minecraft:chest 2" % a.name); quiet(1.0); tick(s, 3)
    both("place chest"); select(s, 0); tick(s, 2)
    s.send("minecraft:use_item_on", use_on(1, -61, 0, 1, sq())); quiet(0.8)
    both("open chest")
    s.send("minecraft:use_item_on", use_on(1, -60, 0, 1, sq())); quiet(1.2)
    k = s.count()
    cid = None
    for e in s.since(k - 50 if k > 50 else 0, {"minecraft:open_screen"}):
        cid, _ = m.parse_varint(e["body"], 0)
    both("close chest")
    s.send("minecraft:container_close", m.varint(cid or 1)); quiet(1.0)
    both("end")
else:
    sys.exit("unknown scenario")
s.dump("%s_%s_surv.jsonl" % (a.out, a.scenario)); o.dump("%s_%s_obs.jsonl" % (a.out, a.scenario))
print("recorded %s_%s_{surv,obs}.jsonl" % (a.out, a.scenario))
s.close(); o.close()
