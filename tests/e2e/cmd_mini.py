#!/usr/bin/env python3
"""A short command session for the commands added after the recorded 392-step session (docs/GAME.md): /experience, /damage, /kick, /defaultgamemode.  Two scripted clients,
operators "Surv" and "Obs" (survival), run the same list of commands against the REAL vanilla server and against dbcraft; per step every packet of the kinds below that either
client received is recorded, and `compare` requires both servers' steps to be equal.

usage: tests/e2e/cmd_mini.py record --port P --out FILE        (vanilla: OPS=Surv,Obs tests/e2e/vanilla_start.sh;  dbcraft: a dev gateway with Surv and Obs as operators)
       tests/e2e/cmd_mini.py compare VANILLA.json OURS.json
Kept: system_chat (exact bytes), set_experience, disconnect, damage_event and entity_event (entity id masked), game_event, set_default_spawn_position, change_difficulty.
Health and regeneration are not compared (their timing differs between the servers by a tick); the packets that say what the command did are.
"""
import json, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

STEPS = [("Surv", c) for c in (
    "experience set Surv 0 levels", "experience set Surv 0 points", "experience add Surv 7 points", "experience add Surv 5 levels", "experience set Surv 0 levels",
    "experience add Surv 100 points", "experience set Surv 30 levels", "experience add Surv -3 levels", "experience set Surv 10000 points", "experience set Surv 5 points",
    "experience query Surv points", "experience query Surv levels", "xp add @a 3 points", "xp set @a 2 levels", "experience add Nobody 3 points", "experience add Surv 3",
    "experience add Surv 1 levels", "experience set Surv 0 levels", "experience query Surv levels", "experience set Surv 0 points",
    "damage Surv 3", "damage Surv 1 minecraft:generic", "damage Surv 2.5", "damage Surv 2 minecraft:fall", "damage @a 1", "damage Nobody 1", "damage Surv 1 minecraft:nonsense",
    "defaultgamemode creative", "defaultgamemode survival", "defaultgamemode adventure", "defaultgamemode survival",
    "kick Nobody", "kick Obs Bye now")]
KEEP = {"minecraft:system_chat", "minecraft:set_experience", "minecraft:disconnect", "minecraft:damage_event", "minecraft:entity_event", "minecraft:game_event",
        "minecraft:set_default_spawn_position", "minecraft:change_difficulty"}
MASK_ID = {"minecraft:damage_event", "minecraft:entity_event"}

def record(port, out, host="127.0.0.1"):
    c = {"Surv": m.Client(host, port, "Surv"), "Obs": m.Client(host, port, "Obs")}
    for x in c.values(): x.settle(1.0, 20.0)
    for x in c.values(): x.send("minecraft:client_command", m.varint(0)); x.settle(0.4, 2.0)
    for who in ("Surv", "Obs"):                      # an earlier probe may have left them in creative (a vanilla world keeps the game mode)
        c["Surv"].send("minecraft:chat_command", m.string("gamemode survival " + who)); time.sleep(0.3)
    for x in c.values(): x.settle(0.4, 2.0)
    res = []
    for who, cmd in STEPS:
        ks = {n: len(x.events) for n, x in c.items()}
        c[who].send("minecraft:chat_command", m.string(cmd))
        for _ in range(8):
            for x in c.values():
                if x.alive: x.send("minecraft:client_tick_end")
            time.sleep(0.05)
        for x in c.values(): x.settle(0.4, 2.0)
        step = {"who": who, "cmd": cmd, "got": {}}
        for n, x in c.items():
            got = []
            for e in x.events[ks[n]:]:
                if e["state"] == "mark" or e["dir"] != "clientbound" or e["name"] not in KEEP: continue
                b = e["body"]
                if e["name"] == "minecraft:damage_event": b = b[m.parse_varint(b, 0)[1]:]          # the entity id (a varint) differs between the servers
                elif e["name"] == "minecraft:entity_event": b = b[4:]
                step["got"][n] = step["got"].get(n, []) + [[e["name"].replace("minecraft:", ""), b.hex()]]
        res.append(step)
        time.sleep(0.3)
    json.dump(res, open(out, "w"), indent=0)
    print("recorded %d steps: %s" % (len(res), out))
    for x in c.values(): x.close()

def compare(a, b):
    va, vb = json.load(open(a)), json.load(open(b)); bad = 0
    for x, y in zip(va, vb):
        assert x["cmd"] == y["cmd"]
        if x["got"] == y["got"]: print("  same     %-5s %-42s %s" % (x["who"], x["cmd"], {k: len(v) for k, v in x["got"].items()})); continue
        bad += 1
        print("  DIFFERENT %-5s %s" % (x["who"], x["cmd"]))
        for k in sorted(set(x["got"]) | set(y["got"])):
            if x["got"].get(k) != y["got"].get(k):
                print("      %s vanilla %s" % (k, [(n, h[:150]) for n, h in x["got"].get(k, [])])); print("      %s dbcraft %s" % (k, [(n, h[:150]) for n, h in y["got"].get(k, [])]))
    print("%d of %d steps identical" % (len(va) - bad, len(va)))
    return bad

if __name__ == "__main__":
    if sys.argv[1] == "record":
        port = int(sys.argv[sys.argv.index("--port") + 1]); out = sys.argv[sys.argv.index("--out") + 1]; record(port, out)
    else:
        sys.exit(1 if compare(sys.argv[2], sys.argv[3]) else 0)
