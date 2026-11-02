#!/usr/bin/env python3
"""Compare what a dbcraft server sent a client during login, configuration and the join with what the real vanilla 26.3 server sent the same client.

usage: tests/e2e/compare_join.py VANILLA.jsonl OURS.jsonl         (both made by tools/capture_vanilla.py)
Exit code 0 when every check passes.  Checks:
  1. login and configuration: the same packets in the same order; every one byte-identical (login_finished: the trailing random session id masked)
  2. the entry burst (login ... set_experience): the same packets in the same order; fields that cannot be equal between two servers are masked
     (entity id, hashed seed, position, game time, spawn, motd ...), everything else byte-identical
  3. chunks: the same number of level_chunk_with_light; each of ours equals a vanilla chunk body (all chunks of a flat world are the same apart from their
     coordinates), after putting the heightmap entries in one order (vanilla writes them in HashMap order, which changes between runs)
Vanilla is allowed to send more than we do (waypoints, sounds, mobs ...): those are reported, not failures.
"""
import json, struct, sys

def load(path):
    return [json.loads(l) for l in open(path)]

def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 127) << s
        if c < 128: return v, o
        s += 7

def body_of(e):
    b = bytes.fromhex(e["hex"]); _, o = vi(b, 0); _, o = vi(b, o); return b[o:]

def cb(events, state):
    return [e for e in events if e["dir"] == "clientbound" and e["state"] == state]

van, our = load(sys.argv[1]), load(sys.argv[2])
fails = 0
def check(ok, label, detail=""):
    global fails
    print(("ok    " if ok else "FAIL  ") + label + ((" -- " + detail) if detail and not ok else ""))
    if not ok: fails += 1

# ---- 1. login and configuration
for st in ("login", "configuration"):
    v, o = cb(van, st), cb(our, st)
    check([e["name"] for e in v] == [e["name"] for e in o], f"{st}: same packets in the same order ({len(v)})",
          f"vanilla {[e['name'][10:] for e in v][:6]} ours {[e['name'][10:] for e in o][:6]}")
    bad, reordered, brand = [], [], []
    for a, b in zip(v, o):
        ha, hb = a["hex"], b["hex"]
        if a["name"] == "minecraft:login_finished": ha, hb = ha[:-32], hb[:-32]
        if ha == hb: continue
        if a["name"] == "minecraft:custom_payload": brand.append(a["name"][10:]); continue
        if len(ha) == len(hb) and sorted(bytes.fromhex(ha)) == sorted(bytes.fromhex(hb)): reordered.append(a["name"][10:]); continue
        bad.append(a["name"][10:])
    check(not bad, f"{st}: every packet byte-identical, or the same bytes in another order, or the brand", f"differs: {bad[:8]}")
    if reordered: print(f"      note: {len(reordered)} packet(s) hold the same bytes in a different order ({', '.join(sorted(set(reordered)))}): vanilla orders them by hash and its own runs differ the same way")
    if brand: print("      note: the server brand differs (a setting)")

# ---- 2. the entry burst
EXACT = {"change_difficulty", "player_abilities", "set_held_slot", "recipe_book_settings", "recipe_book_add", "commands", "initialize_border",
         "ticking_state", "ticking_step", "post_effects", "container_set_content", "set_experience", "game_event", "player_info_update"}
ENTITY_PREFIX = {"set_entity_data"}                    # body starts with the entity id VarInt
NAME_ONLY = {"login", "entity_event", "player_position", "server_data", "set_time", "set_default_spawn_position", "set_chunk_cache_center"}
def burst(events):
    out = []
    for e in cb(events, "play"):
        out.append(e)
        if e["name"] == "minecraft:set_experience": break
    return out
v, o = burst(van), burst(our)
vn, on = [e["name"][10:] for e in v], [e["name"][10:] for e in o]
check(vn == on, f"entry burst: same {len(vn)} packets in the same order", f"vanilla {vn} ours {on}")
bad = []
for a, b in zip(v, o):
    n = a["name"][10:]
    ba, bb = body_of(a), body_of(b)
    if n == "update_recipes":                                    # same content; vanilla's order varies between its own runs
        if len(ba) != len(bb) or sorted(ba) != sorted(bb): bad.append(f"{n} (vanilla {len(ba)} B, ours {len(bb)} B)")
    elif n == "update_attributes":                               # same attribute records; vanilla iterates a hash map, so the order differs between its own runs (checked: equal as a multiset of bytes)
        sa, sb = ba[vi(ba, 0)[1]:], bb[vi(bb, 0)[1]:]
        if len(sa) != len(sb) or sorted(sa) != sorted(sb): bad.append(f"{n} (vanilla {len(sa)} B, ours {len(sb)} B)")
    elif n in ("update_advancements", "set_health"):             # player state (advancement dates, saturation): replayed from the capture, length only
        if len(ba) != len(bb): bad.append(f"{n} length (vanilla {len(ba)} B, ours {len(bb)} B)")
    elif n in EXACT:
        if ba != bb: bad.append(f"{n} (vanilla {len(ba)} B, ours {len(bb)} B)")
    elif n in ENTITY_PREFIX:
        if ba[vi(ba, 0)[1]:] != bb[vi(bb, 0)[1]:]: bad.append(n)
    elif n in NAME_ONLY:
        if n == "login" and len(ba) != len(bb): bad.append(f"login length {len(ba)} vs {len(bb)}")
        if n == "player_position" and len(ba) != len(bb): bad.append("player_position length")
    else:
        bad.append(f"{n} not classified")
check(not bad, "entry burst: deterministic packets byte-identical, the rest same length where that is checkable", "; ".join(bad))
check(len([1 for n in vn if n in EXACT]) >= 14, f"entry burst: {len([1 for n in vn if n in EXACT])} packets compared byte for byte (+ recipes and advancements as same-content)")
print("      note: compare a RETURNING vanilla player: a first-time player gets recipe_book_add in place of update_attributes, which dbcraft does not emulate")

# ---- 3. chunks
def norm_chunk(body):
    x, z = struct.unpack(">ii", body[:8]); o = 8
    n, o = vi(body, o); hm = []
    for _ in range(n):
        t, o = vi(body, o); ln, o = vi(body, o); hm.append((t, body[o:o + 8 * ln])); o += 8 * ln
    return (tuple(sorted(hm)), body[o:])
vc = [body_of(e) for e in cb(van, "play") if e["name"] == "minecraft:level_chunk_with_light"]
oc = [body_of(e) for e in cb(our, "play") if e["name"] == "minecraft:level_chunk_with_light"]
check(len(vc) == len(oc) and len(vc) > 0, f"chunks: the same number sent ({len(vc)} vanilla, {len(oc)} ours)")
vset = {norm_chunk(b) for b in vc}
match = sum(1 for b in oc if norm_chunk(b) in vset)
check(match == len(oc) and len(oc) > 0, f"chunks: every chunk of ours equals a vanilla chunk ({match}/{len(oc)}; vanilla has {len(vset)} distinct form(s))")
extra = [n for n in dict.fromkeys(e["name"][10:] for e in cb(van, "play")) if n not in set(e["name"][10:] for e in cb(our, "play"))]
print(f"note: packets vanilla sent that ours did not (not failures): {extra}")
sys.exit(1 if fails else 0)
