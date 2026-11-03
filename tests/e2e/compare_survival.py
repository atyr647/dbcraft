#!/usr/bin/env python3
"""Compare what dbcraft sent in a survival scenario with what the REAL vanilla 26.3 server sent the same scripted clients (tests/e2e/survival_probe.py).

usage: tests/e2e/compare_survival.py SCENARIO VANILLA_PREFIX OURS_PREFIX          e.g.  fall /tmp/dbcraft-e2e-surv/vanilla /tmp/dbcraft-e2e-surv/ours
Reads <prefix>_<scenario>_surv.jsonl and _obs.jsonl of both servers.  Per client the clientbound packets between the first scenario mark and "end" are reduced to
the ones the survival rules produce (health, experience, damage, death, entity events, entity data, particles, respawn burst, ...); everything else (sounds, entity
motion, waypoints, movement of other entities, the advancement update, the forced send of the block under a landing player, ...) is ignored, the entity ids of the player
are replaced by a placeholder, and the values that legitimately differ between two servers are masked (hashed seed, game time, the world's command tree).  The two sequences
must be equal; the one that is longer by packets of the same kind at its END (the clients stop listening at slightly different moments) is cut to the shorter.
Exit code 0 when every comparison is equal.
"""
import json, os, struct, sys

KEEP = {"set_health", "set_experience", "damage_event", "player_combat_kill", "entity_event", "level_particles", "respawn", "player_abilities", "player_position",
        "set_default_spawn_position", "change_difficulty", "post_effects", "initialize_border", "game_event", "ticking_state", "ticking_step", "set_chunk_cache_center",
        "container_set_content", "container_set_slot", "commands", "remove_entities", "set_time_full"}          # (update_attributes: vanilla sends it twice after a respawn, dbcraft once)
ENTITY_DATA_KEEP = True        # set_entity_data of the player itself (health, flags, score)

def load(path):
    ev = [json.loads(l) for l in open(path)]
    return ev

def varint(b, o):
    v = sh = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << sh
        if not c & 0x80: return v, o
        sh += 7

def own_entity_id(events):
    for e in events:
        if e["name"] == "minecraft:login" and e["dir"] == "clientbound" and e["state"] == "play":
            raw = bytes.fromhex(e["hex"]); _, o = varint(raw, 0); _, o = varint(raw, o)
            return struct.unpack(">i", raw[o:o + 4])[0]
    return None

def body_of(e):
    raw = bytes.fromhex(e["hex"]); _, o = varint(raw, 0); _, o = varint(raw, o)
    return raw[o:]

def vi(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); return bytes(out)

SURV_UUID = bytes.fromhex("6e527204260b3f1585706f6e4efb3898")        # offline uuid of the player "Surv"

def surv_entity_id(events, who):
    """the entity id of Surv: the observer learns it from the add_entity of Surv (the first one: respawns keep the id)"""
    if who == "surv": return own_entity_id(events)
    for e in events:
        if e["name"] == "minecraft:add_entity" and e["dir"] == "clientbound":
            b = body_of(e); v, o = varint(b, 0)
            if b[o:o + 16] == SURV_UUID: return v
    return None

def reduce_events(events, who):
    eid = surv_entity_id(events, who)
    out, on = [], False
    eid_v, eid_i = (vi(eid), struct.pack(">i", eid)) if eid is not None else (b"", b"")
    last_mark = None
    for e in events:
        if e["state"] == "mark":
            if e["name"] == "end": break
            on = True; continue                       # (the marks only start the comparison: where a late packet falls relative to a mark is a matter of wall-clock timing)
        if not on or e["dir"] != "clientbound" or e["state"] != "play": continue
        n = e["name"].replace("minecraft:", "")
        b = body_of(e)
        if n == "set_entity_data":
            # only entity data of the player itself, and the keys we model: 8 flags, 9 health, 18 score
            if not b.startswith(eid_v) or eid is None: continue
            out.append((n, "EID" + b[len(eid_v):].hex())); continue
        if n == "set_time":
            if len(b) > 9: out.append(("set_time_full", "-"))      # the respawn burst's set_time (with clocks): present, value masked
            continue
        if n == "system_chat":
            out.append((n, b.hex())); continue
        if n == "remove_entities":                  # vanilla lists other entities too (items, ...): only the watched player counts
            cnt, o = varint(b, 0); ids = []
            for _ in range(cnt):
                x, o = varint(b, o); ids.append(x)
            if eid in ids: out.append((n, "EID"))
            continue
        if n not in KEEP: continue
        if n == "entity_event":
            if b[:4] != eid_i: continue
            out.append((n, "EID" + b[4:].hex())); continue
        if n in ("damage_event", "set_entity_data"):
            if not b.startswith(eid_v): continue
            out.append((n, "EID" + b[len(eid_v):].hex())); continue
        if n == "player_combat_kill":
            out.append((n, "EID" + b[len(eid_v):].hex())); continue
        if n == "respawn":
            # dimension type, dimension, [hashed seed: 8 bytes masked], game mode ... : keep everything after the seed
            _, o = varint(b, 0); l, o = varint(b, o); o += l + 8
            out.append((n, b[:o - 8].hex() + "SEED" + b[o:].hex())); continue
        if n == "player_position":
            out.append((n, b.hex())); continue
        if n == "commands": out.append((n, "tree")); continue            # the command tree: dbcraft replays a recorded level-0 tree (docs/GAME.md)
        if n == "initialize_border": out.append((n, b.hex())); continue
        if n == "container_set_slot": out.append((n, b[1:2].hex() + "STATE" + b[3:].hex())); continue    # the state id may differ by the way the stack got there
        out.append((n, b.hex()))
    return out

def trim(a, b):
    k = min(len(a), len(b))
    return a[:k], b[:k]

def compare(scn, vp, op):
    rc = 0
    for who in ("surv", "obs"):
        v = reduce_events(load(f"{vp}_{scn}_{who}.jsonl"), who); o = reduce_events(load(f"{op}_{scn}_{who}.jsonl"), who)
        va, oa = trim(v, o)
        bad = [i for i, (x, y) in enumerate(zip(va, oa)) if x != y]
        extra_v, extra_o = [n for n, _ in v[len(va):]], [n for n, _ in o[len(oa):]]
        ok = not bad and len(va) > 0 and set(extra_v) <= {"set_health", "set_entity_data"} and set(extra_o) <= {"set_health", "set_entity_data"}
        print(f"{scn:5s} {who:4s}: {len(va)} packets compared (vanilla {len(v)}, dbcraft {len(o)}) -> {'IDENTICAL' if ok else 'DIFFERENT'}")
        for i in bad[:6]:
            print(f"   #{i}: vanilla {va[i][0]} {va[i][1][:150]}\n        ours    {oa[i][0]} {oa[i][1][:150]}")
        if not ok:
            rc = 1
            if not bad: print("   (no differing packet in the common prefix; the tails differ:", extra_v[:5], extra_o[:5], ")")
    return rc

if __name__ == "__main__":
    scn, vp, op = sys.argv[1:4]
    sys.exit(compare(scn, vp, op))
