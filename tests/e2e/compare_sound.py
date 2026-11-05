#!/usr/bin/env python3
"""Compare the SOUNDS dbcraft sends with what the REAL vanilla 26.3 server sent the same scripted clients (tests/e2e/sound_probe.py and the survival scenarios of
tests/e2e/survival_probe.py: fall, kill, void, eat).

usage: tests/e2e/compare_sound.py SCENARIO VANILLA_PREFIX OURS_PREFIX [--sounds-only]       e.g.  place /tmp/x/vanilla /tmp/x/ours
Reads <prefix>_<scenario>_surv.jsonl and _obs.jsonl of both servers.  Per client and per step (the recordings' marks) the clientbound packets that matter here are reduced and
compared in order:
  * `sound` / `sound_entity`: the sound event NAME (registry), source, position in 1/8 blocks, volume, pitch; the random seed is always masked; the pitch (and for eating the
    volume) is masked for the sounds whose pitch vanilla draws at random (see RANDOM below, from the bytecode); everything else must be equal;
  * the packets around them that fix their ORDER: damage_event, entity_event, block_update, block_changed_ack, block_event, swing_animation, set_equipment (names; the
    bytes of block_update and block_event), unless --sounds-only.
Exit code 0 when every step is equal.
"""
import json, os, struct, sys

REGS = json.load(open(os.path.join(os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")), "registries.json")))
SND = {v["protocol_id"]: k.replace("minecraft:", "") for k, v in REGS["minecraft:sound_event"]["entries"].items()}
# sounds whose pitch / volume vanilla draws at random (LivingEntity.triggerItemUseEffects: volume 0.5 + 0.5 * nextInt(2), pitch (r - r) * 0.2 + 1; LivingEntity.eat: pitch
# 1 + (r - r) * 0.4; Player.eat burp: pitch r * 0.1 + 0.9; ChestBlockEntity / EnderChest / Barrel lids: pitch r * 0.1 + 0.9); everything else is a constant
RANDOM_PITCH = {"entity.item.pickup", "entity.generic.eat", "entity.generic.drink", "entity.player.burp", "block.chest.open", "block.chest.close", "block.ender_chest.open", "block.ender_chest.close",
                "block.barrel.open", "block.barrel.close"}
RANDOM_VOLUME = {"entity.generic.eat", "entity.generic.drink"}
CONTEXT = {"damage_event", "entity_event", "block_update", "block_changed_ack", "block_event", "swing_animation", "set_equipment"}
SOUNDS_ONLY = "--sounds-only" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]

def varint(b, o):
    v = sh = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << sh
        if not c & 0x80: return v, o
        sh += 7

scn_name = [a for a in sys.argv[1:] if not a.startswith("--")][:1] or [""]
scn_name = scn_name[0]

def reduce(path):
    steps, cur = {}, None
    order = []
    for l in open(path):
        e = json.loads(l)
        if e["state"] == "mark":
            cur = e["name"]; steps[cur] = []; order.append(cur); continue
        if cur is None or e["dir"] != "clientbound" or e["state"] != "play": continue
        n = e["name"].replace("minecraft:", "")
        raw = bytes.fromhex(e["hex"]); _, o = varint(raw, 0); _, o = varint(raw, o); b = raw[o:]
        if n == "sound":
            hid, o = varint(b, 0); src, o = varint(b, o)
            x, y, z = struct.unpack(">iii", b[o:o + 12]); vol, pit = struct.unpack(">ff", b[o + 12:o + 20])
            nm = SND.get(hid - 1, "?%d" % (hid - 1))
            steps[cur].append(("sound", nm, src, x, y, z, "V" if nm in RANDOM_VOLUME else round(vol, 4), "P" if nm in RANDOM_PITCH else round(pit, 4)))
        elif n == "sound_entity":
            hid, o = varint(b, 0); src, o = varint(b, o); eid, o = varint(b, o); vol, pit = struct.unpack(">ff", b[o:o + 8])
            nm = SND.get(hid - 1, "?%d" % (hid - 1))
            steps[cur].append(("sound_entity", nm, src, "V" if nm in RANDOM_VOLUME else round(vol, 4), "P" if nm in RANDOM_PITCH else round(pit, 4)))
        elif n in CONTEXT and not SOUNDS_ONLY and not (n == "set_equipment" and scn_name == "eat"):      # (eat: vanilla re-sends the held item when the use starts, a visibility-tracker difference, docs/DIFFERENCES.md)
            item = (n, b.hex()) if n in ("block_update", "block_event") else (n,)
            if n == "block_event" and item in steps[cur]: continue         # an open chest's lid is signalled again every 5 ticks: how many depends on the timing, one is kept
            steps[cur].append(item)
    return order, steps

if len(args) != 3: sys.exit(__doc__)
scn, vp, op = args
bad = total = 0
for who in ("surv", "obs"):
    vo, vs = reduce("%s_%s_%s.jsonl" % (vp, scn, who)); oo, os_ = reduce("%s_%s_%s.jsonl" % (op, scn, who))
    for st in vo:
        if st == "end": continue
        a, b = vs.get(st, []), os_.get(st, [])
        total += 1
        # dbcraft's tick can end a window earlier or later: a window is compared as it is; the sounds are the point
        if a == b: print("  same     %-5s %-28s %d packets" % (who, st, len(a))); continue
        bad += 1
        print("  DIFFERENT %-5s %-27s vanilla %d, dbcraft %d" % (who, st, len(a), len(b)))
        for i in range(max(len(a), len(b))):
            x = a[i] if i < len(a) else None; y = b[i] if i < len(b) else None
            print("      %s %s\n        vanilla %s\n        dbcraft %s" % ("=" if x == y else "!", i, x, y) if x != y else "      = %s %s" % (i, x))
print("%s: %d of %d client steps identical" % (scn, total - bad, total))
sys.exit(1 if bad else 0)
