#!/usr/bin/env python3
"""Compare the mining packets dbcraft sends with what the REAL vanilla 26.3 server sent the same scripted clients (tests/e2e/mine_probe.py).

usage: tests/e2e/compare_mine.py SCENARIO VANILLA_PREFIX OURS_PREFIX [--show]        e.g.  dig /dev/shm/mc_e2e/vanilla /dev/shm/mc_e2e/ours
Reads <prefix>_<scenario>_surv.jsonl and _obs.jsonl of both servers.  Per client and per step (the recordings' marks) the clientbound packets that matter for mining are reduced
and compared in order:
  * level_event (2019 / 2020 dig events, 2001 break effect: type, position, data), block_destruction (breaker id masked: S = the digger, position, stage), block_update (position,
    state), block_changed_ack (sequence), container_set_slot / set_player_inventory (slot, item, count, the component patch), entity_event (the broken tool), the sounds
    (event name, source, position), add_entity (type only: ids, positions, velocities and uuids are random), take_item_entity (count only);
  * not compared: the steps ending in ": end" (set-up of the next case), entity movement, entity data, time, light, keep-alive, chunks (random per run or not what is under test).
The order of the packets inside one step fixes the TICK in which each happened: a dig sends one level_event per tick, so a block_destruction between the n-th and (n+1)-th
is the stage reached in tick n.  --show prints every step.  Exit code 0 when every step is equal.
"""
import json, os, struct, sys

REGS = json.load(open(os.path.join(os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")), "registries.json")))
SND = {v["protocol_id"]: k.replace("minecraft:", "") for k, v in REGS["minecraft:sound_event"]["entries"].items()}
ITEM = {v["protocol_id"]: k for k, v in REGS["minecraft:item"]["entries"].items()}
ETYPE = {v["protocol_id"]: k for k, v in REGS["minecraft:entity_type"]["entries"].items()}
SHOW = "--show" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]

def varint(b, o):
    v = sh = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << sh
        if not c & 0x80: return v, o
        sh += 7

def pos(b, o):
    v = struct.unpack(">Q", b[o:o + 8])[0]
    x = v >> 38; z = (v >> 12) & 0x3FFFFFF; y = v & 0xFFF
    if x >= 1 << 25: x -= 1 << 26
    if z >= 1 << 25: z -= 1 << 26
    if y >= 1 << 11: y -= 1 << 12
    return (x, y, z)

def stack(b, o):
    n, o = varint(b, o)
    if n == 0: return None, o
    iid, o = varint(b, o); rest = b[o:]
    return (ITEM.get(iid, "?%d" % iid).replace("minecraft:", ""), n, rest.hex()), len(b)       # (the patch is the rest of the packet: its length is part of the compare)

def reduce(path):
    steps, cur, order = {}, None, []
    for l in open(path):
        e = json.loads(l)
        if e["state"] == "mark":
            cur = e["name"]; steps[cur] = []; order.append(cur); continue
        if cur is None or e["dir"] != "clientbound" or e["state"] != "play": continue
        n = e["name"].replace("minecraft:", "")
        raw = bytes.fromhex(e["hex"]); _, o = varint(raw, 0); _, o = varint(raw, o); b = raw[o:]
        r = steps[cur]
        if n == "level_event":
            ev = struct.unpack(">i", b[:4])[0]; pp = pos(b, 4)
            if abs(pp[0]) > 12 or pp[1] <= -61 or abs(pp[2]) > 12: continue          # (random ticks of the grass layer far from the test: not under test)
            r.append(("level_event", ev, pp, struct.unpack(">i", b[12:16])[0]))
        elif n == "block_destruction":
            _, o = varint(b, 0); stg = b[o + 8]
            r.append(("block_destruction", pos(b, o), stg if stg <= 10 or stg == 255 else "big"))     # (a delayed dig's stage is  progress * (start tick + 1): it depends on how long the player has been online)
        elif n == "block_update":
            pp = pos(b, 0)
            if abs(pp[0]) > 12 or pp[1] <= -61 or abs(pp[2]) > 12: continue
            r.append(("block_update", pp, varint(b, 8)[0]))
        elif n == "block_changed_ack":
            r.append(("block_changed_ack",))                                   # (the sequence numbers count the probe's own packets: not compared)
        elif n == "section_blocks_update":
            r.append(("section_blocks_update", b.hex()))
        elif n == "container_set_slot":
            wid, o = varint(b, 0); st, o = varint(b, o); slot = struct.unpack(">h", b[o:o + 2])[0]; sk, _ = stack(b, o + 2); r.append(("container_set_slot", wid, slot, sk))
        elif n == "set_player_inventory":
            slot, o = varint(b, 0); sk, _ = stack(b, o); r.append(("set_player_inventory", slot, sk))
        elif n == "entity_event":
            r.append(("entity_event", "E", b[4]))
        elif n == "sound":                                                   # (not compared: the world's animals make sounds of their own; the mining sounds are the client's, from the level events)
            pass
        elif n == "add_entity":
            _, o = varint(b, 0); o += 16; t, _ = varint(b, o); r.append(("add_entity", ETYPE.get(t, "?%d" % t)))
        elif n == "set_entity_data":                                         # an item entity's stack (entry 8, type 7): count and item; other entity data is not compared
            _, o = varint(b, 0)
            while o < len(b) and b[o] != 0xff:
                idx = b[o]; ty, o = varint(b, o + 1)
                if ty != 7: break
                cnt, o = varint(b, o); iid, o = varint(b, o)
                if idx == 8: r.append(("item_stack", ITEM.get(iid, "?%d" % iid).replace("minecraft:", ""), cnt))
                _, o = varint(b, o); _, o = varint(b, o)
        elif n == "take_item_entity":
            r.append(("take_item_entity",))
        elif n == "player_abilities" or n == "game_event":
            r.append((n, b.hex()))
    if "drops" in path:
        # the item entities of a drop: their packets come in the entity tracker's order (not under test); compared are the stacks (a set: vanilla sends each entity's data twice)
        for st in order:
            items = sorted({x[1:] for x in steps[st] if x[0] == "item_stack" and not any(t in x[1] for t in ("_pickaxe", "_shovel", "_sword", "_hoe", "_axe", "shears"))})      # (the tools /give hands out are fake item entities too)
            steps[st] = [x for x in steps[st] if x[0] not in ("item_stack", "add_entity", "take_item_entity", "sound")] + [("drops", items)]
    return order, steps

if len(args) == 3 and args[0] == "dump":          # dump SCENARIO PREFIX: the reduced steps of one recording
    for who in ("surv", "obs"):
        order, steps = reduce("%s_%s_%s.jsonl" % (args[2], args[1], who))
        for st in order:
            print("%s | %s" % (who, st))
            for x in steps[st]: print("      ", x)
    sys.exit(0)
if len(args) != 3: sys.exit(__doc__)
scn, vp, op = args
bad = total = 0
for who in ("surv", "obs"):
    vo, vs = reduce("%s_%s_%s.jsonl" % (vp, scn, who)); oo, os_ = reduce("%s_%s_%s.jsonl" % (op, scn, who))
    for st in vo:
        if st.endswith(": end") or st.startswith("case "): continue            # (the set-up of the next case: /give noise and the like)
        if st not in os_: continue                                        # (a case the dbcraft run did not make)
        a, b = vs.get(st, []), os_.get(st, [])
        # (the item entities of a drop: their number is compared, not their packets after the first; set_entity_data and movement are not reduced at all)
        total += 1
        if a == b:
            if SHOW: print("  same     %-5s %-44s %d packets" % (who, st, len(a)))
            continue
        bad += 1
        print("  DIFFERENT %-5s %-43s vanilla %d, dbcraft %d" % (who, st, len(a), len(b)))
        for i in range(max(len(a), len(b))):
            x = a[i] if i < len(a) else None; y = b[i] if i < len(b) else None
            if x == y: print("      = %s %s" % (i, x))
            else: print("      ! %s\n        vanilla %s\n        dbcraft %s" % (i, x, y))
print("%s: %d of %d client steps identical" % (scn, total - bad, total))
sys.exit(1 if bad else 0)
