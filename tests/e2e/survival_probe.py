#!/usr/bin/env python3
"""Survival scenarios driven by scripted clients.  Run against the REAL vanilla server to record what it sends, and against a dbcraft database to compare
(tests/e2e/compare_survival.py).  Everything the clients receive is recorded byte for byte (`mcclient.Client.dump`).

usage: tests/e2e/survival_probe.py SCENARIO [--host 127.0.0.1] [--port 25631] [--out /tmp/dbcraft-e2e/vanilla_surv] [--height 12]
  SCENARIO  fall      Surv is teleported `height` blocks up and falls to the floor (client physics: gravity 0.08, drag 0.98), Obs watches; then ~4 s of regeneration
            kill      Surv runs /kill; ~2 s later asks to respawn (client_command perform_respawn); Obs watches
            void      Surv is teleported below the world (y = -140) and stays there until dead; Obs watches
            eat       Surv is given an apple, then uses it (use_item) and waits for it to be eaten
            xp        Surv is given experience (/xp is vanilla's /experience) in a few steps
The server must run in survival mode, difficulty normal, no mobs, world spawn 0 -60 0 with spawn radius 0, and Surv must be an operator.
Writes <out>_<scenario>_surv.jsonl and <out>_<scenario>_obs.jsonl (marks name the steps).
"""
import argparse, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("scenario")
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25631)
ap.add_argument("--out", default="/tmp/dbcraft-e2e/vanilla_surv")
ap.add_argument("--height", type=int, default=12)
ap.add_argument("--drain", action="store_true", help="eat: lower the food level first (vanilla only: uses the Hunger effect)")
ap.add_argument("--name", default="Surv"); ap.add_argument("--observer", default="Obs")
a = ap.parse_args()
os.makedirs(os.path.dirname(a.out), exist_ok=True)

def cmd(c, text):
    c.send("minecraft:chat_command", m.string(text))

def health(c):
    """(health, food, saturation) of the last set_health the client received"""
    for e in reversed(c.events):
        if e["name"] == "minecraft:set_health" and e["dir"] == "clientbound":
            h, = struct.unpack(">f", e["body"][:4]); f, o = m.parse_varint(e["body"], 4); s, = struct.unpack(">f", e["body"][o:o + 4])
            return h, f, s
    return None

def tick(c, n=1):
    for _ in range(n):
        c.send("minecraft:client_tick_end"); time.sleep(0.05)

def stand(c, n=1):
    """n ticks standing still (status-only move packets: on ground)"""
    for _ in range(n):
        c.send("minecraft:client_tick_end"); c.send("minecraft:move_player_status_only", b"\x01"); time.sleep(0.05)

def join():
    s = m.Client(a.host, a.port, a.name); o = m.Client(a.host, a.port, a.observer)
    s.settle(1.0, 20.0); o.settle(1.0, 15.0)
    for c in (s, o):                       # a player that quit dead comes back dead: get up
        h = health(c)
        if h and h[0] == 0.0:
            c.send("minecraft:client_command", m.varint(0)); c.settle(1.0, 5.0)
    return s, o

def both(s, o, label):
    s.mark(label); o.mark(label)

def settle_all(s, o, quiet=0.5, timeout=4.0):
    s.settle(quiet, timeout); o.settle(quiet, timeout)

def fall(s, x, y0, z, floor=-60.0, oneshot=False):
    """client physics: a falling player sends one position per tick; the step that reaches the floor is on the ground"""
    y, vy = y0, 0.0
    for _ in range(400):
        s.send("minecraft:client_tick_end")
        vy = (vy - 0.08) * 0.98
        ny = y + vy; og = 0
        if ny <= floor:
            ny = floor; og = 1
        s.send("minecraft:move_player_pos", struct.pack(">ddd", x, ny, z) + bytes([og]))
        y = ny
        time.sleep(0.05)
        if og: return

s, o = join()
spawn = s.pos
print("spawn", spawn, o.pos)
if a.scenario == "fall":
    cmd(s, "tp %s 0.5 -60 0.5" % a.name); cmd(s, "tp %s 4.5 -60 0.5" % a.observer); settle_all(s, o, 1.0)
    stand(s, 4)
    both(s, o, "tp up")
    cmd(s, "tp %s 0.5 %d 0.5" % (a.name, -60 + a.height)); settle_all(s, o, 0.6)
    both(s, o, "fall")
    fall(s, 0.5, -60.0 + a.height, 0.5)
    both(s, o, "landed")
    for _ in range(80): stand(s)           # four seconds on the ground: natural regeneration
    both(s, o, "end")
elif a.scenario == "kill":
    stand(s, 4); both(s, o, "kill")
    cmd(s, "kill"); settle_all(s, o, 0.4)
    time.sleep(1.6); tick(s, 5); settle_all(s, o, 0.5)
    both(s, o, "respawn")
    s.send("minecraft:client_command", m.varint(0)); settle_all(s, o, 1.0, 6.0)
    stand(s, 20); both(s, o, "end")
elif a.scenario == "void":
    cmd(s, "tp %s 0.5 -60 0.5" % a.name); settle_all(s, o, 1.0); stand(s, 4)
    both(s, o, "void")
    cmd(s, "tp %s 0.5 -140 0.5" % a.name); settle_all(s, o, 0.4)
    for _ in range(40): tick(s)            # (no position packets: the server's idea of the position is the teleport target)
    settle_all(s, o, 0.5); both(s, o, "end")
elif a.scenario == "eat":
    cmd(s, "give %s minecraft:apple 3" % a.name); settle_all(s, o, 1.0); stand(s, 2)
    if a.drain:                            # vanilla only (dbcraft has no effects): the Hunger effect empties the food bar quickly; the harness copies the state
        cmd(s, "effect give %s minecraft:hunger 3 200" % a.name)
        for _ in range(100):
            stand(s)
            if health(s)[1] < 20: break
        cmd(s, "effect clear %s" % a.name); stand(s, 10); settle_all(s, o, 0.5)
        print("food state before eating:", health(s))
    both(s, o, "use apple")
    s.send("minecraft:use_item", m.varint(0) + m.varint(1) + struct.pack(">ff", 0.0, 0.0))
    for _ in range(50): stand(s)
    settle_all(s, o, 0.5); both(s, o, "end")
elif a.scenario == "xp":
    for step in ("experience add %s 7 points", "experience add %s 5 levels", "experience set %s 0 levels", "experience add %s 100 points", "experience set %s 30 levels", "experience add %s 1 levels"):
        both(s, o, step % a.name); cmd(s, step % a.name); settle_all(s, o, 0.4)
    both(s, o, "end")
else:
    sys.exit("unknown scenario " + a.scenario)
time.sleep(0.5)
s.dump(f"{a.out}_{a.scenario}_surv.jsonl"); o.dump(f"{a.out}_{a.scenario}_obs.jsonl")
print("recorded", f"{a.out}_{a.scenario}_surv.jsonl", f"{a.out}_{a.scenario}_obs.jsonl")
s.close(); o.close()
