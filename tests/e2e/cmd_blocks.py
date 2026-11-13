#!/usr/bin/env python3
"""A command session for the block-position commands and what goes with them (docs/MINING-AND-COMMANDS.md): /setblock, /fill, /spawnpoint, /setworldspawn, /weather, /time query,
/title /subtitle /actionbar /tellraw.  Two scripted clients, operators "Surv" and "Obs" (survival), run the same list of commands against the REAL vanilla server and against
dbcraft; per step every packet of the kinds below that either client received is recorded, and `compare` requires both servers' steps to be equal.

usage: tests/e2e/cmd_blocks.py record --port P --out FILE [--dbcraft] [--group NAME[,NAME]]     (vanilla: OPS=Surv,Obs tests/e2e/vanilla_start.sh;  dbcraft: a dev gateway with Surv and Obs as operators)
       tests/e2e/cmd_blocks.py compare VANILLA.json OURS.json [--group NAME]
Groups: setblock fill spawn weather time title.  The world edits of the set-up (not recorded) go through /fill on vanilla and psql (the PG* variables) on dbcraft.
Kept: system_chat (exact bytes), block_update (not the grass layer: random ticks), section_blocks_update (exact bytes), level_event, set_default_spawn_position, title
packets, set_time (only in the `time` group), add_entity (the type only).  Game events (the weather) are tests/e2e/weather_probe.py's.  The world and the clients' positions are the same at the start of every group.
"""
import json, os, subprocess, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

GROUPS = {
  "setblock": [("Surv", c) for c in (
    "setblock 0 -60 5 stone", "setblock 0 -60 5 stone", "setblock 0 -60 5 minecraft:oak_log[axis=x]", "setblock 0 -60 5 oak_log[axis=x] keep", "setblock 0 -60 6 oak_log keep",
    "setblock 0 -60 5 air destroy", "setblock 0 -60 5 air destroy", "setblock 0 -60 5 stone replace", "setblock ~ ~ ~ glass", "setblock ~1 ~2 ~-3 oak_planks", "setblock ^ ^ ^3 stone",
    "setblock ^1 ^ ^3 stone", "setblock 0 -60 7 oak_stairs[facing=north,half=top]", "setblock 0 -60 8 oak_door[half=lower]", "setblock 0 -60 9 chest",
    "setblock 0 -60 5 stone destroy", "setblock 0 -60 5 oak_planks destroy", "setblock 0 -60 5 stone strict", "setblock 0 -60 5 air",
    "setblock 0 -60 10 stone[foo=bar]", "setblock 0 -60 10 oak_log[axis=q]", "setblock 0 -60 10 oak_log[axis]", "setblock 0 -60 10 oak_log[axis=x", "setblock 0 -60 10 oak_log[axis=x,axis=y]",
    "setblock 0 -60 10 nonsense", "setblock 0 -60 10 Stone", "setblock 0 -60 10 #minecraft:logs", "setblock 0 -60 10 ", "setblock 0 -60", "setblock 0 -60 x stone",
    "setblock 0 400 0 stone", "setblock 0 -70 0 stone", "setblock 100000 0 0 stone", "setblock 40000000 0 0 stone", "setblock 0.5 -60 10 stone", "setblock ~ ^ ~ stone",
    "setblock 0 -60 10 stone foo", "setblock 0 -60 11 air", "setblock 0 -60 11 stone[]", "setblock 0 -60 11 oak_log[ axis = z ]",
    "setblock 0 -60 12 air replace", "setblock 3 -60 11 minecraft:stone[]", "setblock ~ ~-1 ~ stone", "setblock 0 -59 12 oak_slab[type=double]", "setblock 0 -59 12 air destroy",
    "setblock 0 -60 13 oak_fence", "setblock 0 -60 14 oak_fence", "setblock 0 -60 13 air destroy")],
  "fill": [("Surv", c) for c in (
    "fill 0 -60 12 3 -58 14 stone", "fill 0 -60 12 3 -58 14 stone", "fill 0 -60 12 3 -58 14 glass hollow", "fill 0 -60 12 3 -58 14 oak_planks outline", "fill 0 -60 12 3 -58 14 air replace stone",
    "fill 0 -60 12 3 -58 14 gold_block replace #minecraft:planks", "fill 0 -60 12 3 -58 14 diamond_block replace oak_planks", "fill 0 -60 12 3 -58 14 stone keep",
    "fill 0 -60 12 3 -58 14 air destroy", "fill ~ ~ ~5 ~2 ~2 ~7 oak_planks", "fill 0 -60 0 47 -30 47 stone", "fill 0 -60 20 31 -50 20 stone", "fill 0 -60 12 3 -58 14 minecraft:nonsense",
    "fill 0 -60 12 3 -58 14 stone replace minecraft:nonsense", "fill 0 -60 12 3 -58 14 stone replace #minecraft:nonsense", "fill 0 -60 12 3 -58 14 stone replace oak_log[axis=q]",
    "fill 100000 0 0 100001 0 0 stone", "fill 0 -60 12 3 -58 stone", "fill 0 -60 12 3 -58 14 stone strict", "fill 3 -58 14 0 -60 12 glass replace stone", "fill 0 -60 12 0 -60 12 stone",
    "fill 0 -60 12 3 -58 14 oak_log[axis=x] replace stone", "fill 0 -60 12 3 -58 14 stone hollow", "fill 0 -60 12 3 -58 14 air hollow", "fill 0 -60 12 1 -60 12 stone replace air",
    "fill ^ ^ ^2 ^1 ^1 ^3 stone", "fill 0 -60 12 3 -58 14 stone replace #minecraft:logs[axis=x]", "fill 0 -60 12 3 -60 14 oak_fence", "fill 0 -60 13 1 -60 13 air destroy")],
  "spawn": [("Surv", c) for c in (
    "tp Surv 0.5 -60 0.5 45 10", "spawnpoint", "spawnpoint Surv", "spawnpoint Surv 5 -60 5", "setworldspawn", "setworldspawn 3 -60 3", "tp Surv 0.5 -60 0.5 0 0",
    "spawnpoint", "spawnpoint Surv", "spawnpoint Surv 5 -60 5", "spawnpoint @a 6 -60 6", "spawnpoint Surv ~ ~ ~", "spawnpoint Surv 5 -60 5 90", "spawnpoint Surv 5 -60 5 90 45",
    "spawnpoint Nobody", "spawnpoint Surv 5 -60", "spawnpoint @a", "spawnpoint Surv ~1 ~ ~-1 ~10 ~5",
    "setworldspawn", "setworldspawn 3 -60 3", "setworldspawn 3 -60 3 90", "setworldspawn 3 -60 3 90 20", "setworldspawn ~ ~ ~", "setworldspawn x", "setworldspawn 3 -60", "setworldspawn 3 -60 3 90 a",
    "setworldspawn 0 -60 0 0 0")],
  "weather": [("Surv", c) for c in (
    "weather clear", "weather rain", "weather rain", "weather thunder", "weather clear", "weather rain 5s", "weather clear 100", "weather thunder 2d", "weather clear 1t", "weather rain 0",
    "weather rain -5", "weather rain x", "weather", "weather snow", "weather clear")],
  "time": [("Surv", c) for c in (
    "time query gametime", "time query time", "time query minecraft:overworld", "time query minecraft:day", "time query minecraft:day repetition", "time query minecraft:nonsense",
    "time set 1000", "time set day", "time add 5", "time add 5t", "time add 1s", "time add 1d", "time set noon", "time set midnight", "time set 100000", "time query time",
    "time pause", "time pause", "time resume", "time resume", "time rate 2", "time rate 1", "time rate 0", "time rate -1", "time rate 1000", "time query time",
    "time of minecraft:overworld query time", "time of minecraft:overworld add 5", "time of minecraft:overworld set 100", "time of minecraft:overworld pause", "time of minecraft:overworld resume",
    "time of minecraft:overworld rate 1", "time of minecraft:overworld query minecraft:day", "time of minecraft:nonsense query time", "time set nonsense", "time set minecraft:noon")],
  "title": [("Surv", c) for c in (
    'title Surv title {"text":"Hi"}', 'title Surv title "plain"', 'title Surv subtitle {"text":"sub","color":"red"}', 'title Surv actionbar {"text":"bar","bold":true}',
    "title Surv times 5 40 5", "title Surv times 1s 2s 3s", "title Surv clear", "title Surv reset", "title @a title {text:'x',italic:true}", 'title Nobody title {"text":"Hi"}',
    'title Surv title ["a",{"text":"b","color":"blue"},"c"]', 'title Surv title {"translate":"chat.type.text","with":["Surv","msg"]}', 'title Surv title {"text":"x","color":"#ff8800"}',
    'title Surv title {"text":"x",}', 'title Surv title {', 'title Surv title', 'title Surv title 5', 'title Surv title true', 'title Surv title {"text":1}', 'title Surv title {"extra":["a"]}',
    'title Surv title {"text":"a","extra":[{"text":"b"},"c"]}', 'title Surv title {"text":"a","hover_event":{"action":"show_text","value":"v"}}',
    'title Surv title {"text":"a","click_event":{"action":"open_url","url":"https://example.com"}}', 'title Surv title {"text":"a","insertion":"i","font":"minecraft:alt","underlined":true,"strikethrough":false,"obfuscated":true}',
    'title Surv title {"score":{"name":"Surv","objective":"o"}}', 'title Surv title {"selector":"@s"}', 'title Surv title {"keybind":"key.jump"}', 'title Surv title {"nbt":"x","entity":"@s"}',
    'tellraw @a {"text":"x"}', 'tellraw @a "plain"', 'tellraw @a ["a",{"text":"b","bold":true}]', 'tellraw Surv {"text":"x","color":"red"}', 'tellraw Surv {"text":"x","color":"nonsense"}',
    'tellraw Surv {"translate":"commands.give.success.single","with":[1,"a","b"]}', 'tellraw Surv {"text":"x","bold":"yes"}', "tellraw Surv x", "tellraw Surv", "tellraw Nobody {text:'x'}",
    "tellraw @s {text:'sel',color:'green'}", "tellraw Surv {'text':'single'}", 'tellraw Surv {"text":"é ü \\u00e9 \\n x"}', 'tellraw Surv [{"text":"a"},{"text":"b"}]', 'tellraw Surv []',
    'tellraw Surv {"text":""}', 'tellraw Surv ""', 'tellraw Surv {}', 'tellraw Surv 12', 'tellraw Surv {"text":"a","color":"red","extra":[{"text":"b","color":"blue"}]}',
    'tellraw Surv {"text":"x","shadow_color":-1}', 'tellraw Surv {"text":"x","shadow_color":[1.0,0.5,0.0,1.0]}')],
}
KEEP = {"minecraft:system_chat", "minecraft:block_update", "minecraft:section_blocks_update", "minecraft:level_event", "minecraft:set_default_spawn_position",
        "minecraft:set_title_text", "minecraft:set_subtitle_text", "minecraft:set_titles_animation", "minecraft:clear_titles", "minecraft:set_action_bar_text", "minecraft:set_time",
        "minecraft:add_entity"}

def psql(sql): subprocess.run(["psql", "-X", "-q", "-At", "-c", sql], check=True, capture_output=True)

def record(port, out, groups, dbcraft, host="127.0.0.1"):
    c = {"Surv": m.Client(host, port, "Surv"), "Obs": m.Client(host, port, "Obs")}
    for x in c.values(): x.settle(1.0, 20.0)
    for x in c.values(): x.send("minecraft:client_command", m.varint(0)); x.settle(0.4, 2.0)
    s = c["Surv"]
    def cmd(t): s.send("minecraft:chat_command", m.string(t))
    def quiet(q=0.4, t=3.0):
        for x in c.values(): x.settle(q, t)
    for who in ("Surv", "Obs"): cmd("gamemode survival " + who); time.sleep(0.2)
    cmd("gamerule block_drops false"); cmd("gamerule send_command_feedback true"); quiet()
    res = []
    for g in groups:
        # set-up: a clean area, both players at known places, same weather / time / spawn
        if dbcraft:
            psql("select mc.fill('minecraft:overworld', -8, -60, -8, 40, -50, 40, 'minecraft:air'), mc.fill('minecraft:overworld', -8, -61, -8, 40, -61, 40, 'minecraft:grass_block[snowy=false]')")
        else:
            cmd("fill -8 -60 -8 40 -50 40 minecraft:air"); cmd("fill -8 -61 -8 40 -61 40 minecraft:grass_block")
        if g == "time": cmd("gamerule advance_time false"); cmd("time resume"); cmd("time rate 1"); cmd("time set 1000")           # (a clock that does not move: the values are comparable)
        cmd("tp Surv 0.5 -60 0.5 0 0"); cmd("tp Obs 20.5 -60 20.5 0 0"); cmd("clear Surv"); cmd("weather clear"); cmd("setworldspawn 0 -60 0 0 0"); quiet(0.6, 4.0)
        for x in c.values():
            for _ in range(4): x.send("minecraft:client_tick_end"); time.sleep(0.05)
        quiet()
        for who, command in GROUPS[g]:
            ks = {n: len(x.events) for n, x in c.items()}
            c[who].send("minecraft:chat_command", m.string(command))
            for _ in range(8):
                for x in c.values():
                    if x.alive: x.send("minecraft:client_tick_end")
                time.sleep(0.05)
            for x in c.values(): x.settle(0.4, 2.0)
            step = {"group": g, "who": who, "cmd": command, "got": {}}
            for n, x in c.items():
                got = []
                for e in x.events[ks[n]:]:
                    if e["state"] == "mark" or e["dir"] != "clientbound" or e["name"] not in KEEP: continue
                    if e["name"] == "minecraft:set_time" and g != "time": continue
                    b = e["body"]
                    if e["name"] == "minecraft:block_update" and m.unposition(b)[1] <= -61: continue           # (random ticks of the grass layer: not under test)
                    if e["name"] == "minecraft:level_event" and (m.unposition(b, 4)[1] <= -61 or abs(m.unposition(b, 4)[0]) > 40 or abs(m.unposition(b, 4)[2]) > 40): continue
                    if e["name"] == "minecraft:add_entity": b = b[m.parse_varint(b, 0)[1] + 16:]; b = m.parse_varint(b, 0)[0].to_bytes(2, "big")
                    step["got"].setdefault(n, []).append([e["name"].replace("minecraft:", ""), b.hex()])
            res.append(step)
            time.sleep(0.2)
    json.dump(res, open(out, "w"), indent=0)
    print("recorded %d steps: %s" % (len(res), out))
    for x in c.values(): x.close()

def drop_periodic(steps):
    """the periodic set_time (every 20 ticks, no clock in it) lands in a window by chance: only the packets that carry a clock are compared, without the game time (it differs per server);
    `time query gametime` says the game time: its number is masked"""
    for st in steps:
        for who in st["got"]:
            st["got"][who] = [e for e in st["got"][who] if not (e[0] == "level_event" and (m.unposition(bytes.fromhex(e[1]), 4)[1] <= -61 or abs(m.unposition(bytes.fromhex(e[1]), 4)[0]) > 40 or abs(m.unposition(bytes.fromhex(e[1]), 4)[2]) > 40))]
            st["got"][who] = [[e[0], "game-time" + e[1][16:]] if e[0] == "set_time" else e for e in st["got"][who] if not (e[0] == "set_time" and e[1][16:18] == "00")]
            if st["cmd"] == "time query gametime": st["got"][who] = [[e[0], e[1][:46]] if e[0] == "system_chat" else e for e in st["got"][who]]
        st["got"] = {k: v for k, v in st["got"].items() if v}
    return steps

def compare(a, b, only):
    va, vb = drop_periodic(json.load(open(a))), drop_periodic(json.load(open(b))); bad = 0; n = 0
    key = lambda s: (s["group"], s["cmd"], s["who"])
    mb = {}
    for y in vb: mb.setdefault(key(y), []).append(y)
    for x in va:
        if only and x["group"] != only: continue
        ys = mb.get(key(x)); y = ys.pop(0) if ys else {"got": {}}
        n += 1
        if x["got"] == y["got"]: print("  same     %-7s %-5s %-62s %s" % (x["group"], x["who"], x["cmd"], {k: len(v) for k, v in x["got"].items()})); continue
        bad += 1
        print("  DIFFERENT %-7s %-5s %s" % (x["group"], x["who"], x["cmd"]))
        for k in sorted(set(x["got"]) | set(y["got"])):
            if x["got"].get(k) != y["got"].get(k):
                print("      %s vanilla %s" % (k, [(nm, h[:180]) for nm, h in x["got"].get(k, [])])); print("      %s dbcraft %s" % (k, [(nm, h[:180]) for nm, h in y["got"].get(k, [])]))
    print("%d of %d steps identical" % (n - bad, n))
    return bad

if __name__ == "__main__":
    if sys.argv[1] == "record":
        port = int(sys.argv[sys.argv.index("--port") + 1]); out = sys.argv[sys.argv.index("--out") + 1]
        groups = sys.argv[sys.argv.index("--group") + 1].split(",") if "--group" in sys.argv else list(GROUPS)
        record(port, out, groups, "--dbcraft" in sys.argv)
    else:
        only = sys.argv[sys.argv.index("--group") + 1] if "--group" in sys.argv else None
        sys.exit(1 if compare(sys.argv[2], sys.argv[3], only) else 0)
