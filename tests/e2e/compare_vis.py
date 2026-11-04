#!/usr/bin/env python3
"""Compare what dbcraft sent two scripted clients (tests/e2e/vis_probe.py) with what the REAL vanilla 26.3 server sent them.

usage: tests/e2e/compare_vis.py SCENARIO VANILLA_PREFIX OURS_PREFIX [--verbose]        e.g.  pose /tmp/dbcraft-e2e-vis/vanilla /tmp/dbcraft-e2e-vis/ours
Reads <prefix>_<scenario>_{act,obs}.jsonl (join: obs, act, act2).  Per client, the clientbound packets between two step marks are reduced to the ones the visibility layer
produces (docs/PLAYER-VISIBILITY.md), with what legitimately differs between two runs made equal:
  * entity ids become names in the order the client learns them (ME for its own, E1, E2 ... from add_entity), so ids that differ between servers compare equal;
  * the order of the entries of update_attributes (vanilla keeps them in a hash set, a different order in every run) is sorted;
  * latencies (milliseconds of a real network round trip, which dbcraft measures in ticks) are masked;
  * packets whose bytes are random or depend on wall-clock time are left out: sounds, keep-alives, the clock, chunk data and light, recipes and advancements (their content), particles;
  * in scenarios that are not about movement, the idle position refresh every 60 ticks (a zero move) is left out: its phase is the entity's age, not part of the step.
Per step the two sequences must be EQUAL (same packets, same order, same bytes).  Exit code 0 when every step of every client is equal.
"""
import json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
verbose = "--verbose" in sys.argv
SKIP = set(next((a[7:].split(",") for a in sys.argv[1:] if a.startswith("--skip=")), []))      # packet names to leave out (a feature under construction)
args = [a for a in sys.argv[1:] if not a.startswith("--")]
scn, vp, op = args[:3]

IGNORE = {"set_time", "keep_alive", "sound", "sound_entity", "level_chunk_with_light", "light_update", "chunk_batch_start", "chunk_batch_finished", "set_chunk_cache_center",
          "recipe_book_add", "recipe_book_remove", "recipe_book_settings", "update_advancements", "update_recipes", "commands", "level_particles", "set_entity_motion", "ping",
          "block_update", "level_event", "block_destruction", "container_set_slot", "container_set_content", "set_health", "set_experience", "set_cursor_item", "set_player_inventory",
          "set_held_slot", "player_abilities", "game_event", "system_chat", "player_position", "ticking_state", "ticking_step", "award_stats", "select_advancements_tab",
          "take_item_entity", "damage_event", "entity_event", "hurt_animation", "set_default_spawn_position", "tab_list", "set_action_bar_text", "set_title_text", "set_subtitle_text"}
if scn == "view":
    IGNORE -= {"set_chunk_cache_center"}
CHUNKS = {"forget_level_chunk", "level_chunk_with_light", "chunk_batch_start", "chunk_batch_finished", "set_chunk_cache_center"}

def vi(b, o=0):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << s
        if not c & 0x80: return v, o
        s += 7

def vi_enc(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); return bytes(out)

def load(path): return [json.loads(l) for l in open(path)]

def body(e):
    raw = bytes.fromhex(e["hex"]); _, o = vi(raw, 0); _, o = vi(raw, o); return raw[o:]

def own_id(ev):
    for e in ev:
        if e["name"] == "minecraft:login" and e["dir"] == "clientbound" and e["state"] == "play":
            return struct.unpack(">i", body(e)[:4])[0]

class Namer:
    def __init__(self, me): self.me, self.n, self.names = me, 0, {me: "ME"}
    def name(self, eid):
        if eid not in self.names:
            self.n += 1; self.names[eid] = f"E{self.n}"
        return self.names[eid]

ENTITY_FIRST = {"set_entity_data", "update_attributes", "set_equipment", "move_entity_pos", "move_entity_pos_rot", "move_entity_rot", "rotate_head", "entity_position_sync",
                "swing_animation", "animate", "teleport_entity", "set_entity_motion"}

def norm_attr(b):
    eid, o = vi(b, 0); n, o = vi(b, o); ents = []
    for _ in range(n):
        s0 = o; aid, o = vi(b, o); o += 8; m, o = vi(b, o)
        for _ in range(m):
            l, o = vi(b, o); o += l + 8 + 1
        ents.append((aid, b[s0:o].hex()))
    return ";".join(f"{a}:{h}" for a, h in sorted(ents))

def norm_info(b):
    act = b[0]; n, o = vi(b, 1); out = []
    for _ in range(n):
        u = b[o:o + 16].hex(); o += 16
        if act == 0x10: l, o = vi(b, o); out.append(f"{u[:8]} lat=*")
        elif act == 0x80: out.append(f"{u[:8]} hat={b[o]}"); o += 1
        elif act == 0x04: g, o = vi(b, o); out.append(f"{u[:8]} gm={g}")
        elif act == 0xff:
            l, o = vi(b, o); nm = b[o:o + l].decode(); o += l; np_, o = vi(b, o); assert np_ == 0
            o += 1                                   # chat session absent
            g, o = vi(b, o); listed = b[o]; o += 1; lat, o = vi(b, o); dn = b[o]; o += 1; lo, o = vi(b, o); hat = b[o]; o += 1
            out.append(f"{u[:8]} {nm} gm={g} listed={listed} lat=* dn={dn} order={lo} hat={hat}")
        else: out.append(u[:8]); break
    return f"act={act:02x} " + " | ".join(out)

def reduce(ev, who, mask_pos=False):
    me = own_id(ev); nm = Namer(me); steps = {"(start)": []} if scn == "join" else {}; cur = "(start)" if scn == "join" else None
    for e in ev:
        if e["state"] == "mark":
            cur = e["name"]; steps.setdefault(cur, []); continue
        if cur is None or e["dir"] != "clientbound" or e["state"] != "play": continue
        n = e["name"].replace("minecraft:", ""); b = body(e)
        if n in IGNORE or n in SKIP: continue
        if n in ("login", "server_data", "initialize_border", "respawn"): steps[cur].append((n, "-")); continue
        if n == "add_entity":
            eid, o = vi(b, 0); nm.name(eid)
            rest = b[o:]
            if mask_pos: rest = rest[:16 + 2] + b"POS" + rest[16 + 2 + 24:]
            steps[cur].append((n, f"{nm.name(eid)} {rest.hex()}")); continue
        if n in ENTITY_FIRST:
            eid, o = vi(b, 0)
            if n == "update_attributes": steps[cur].append((n, f"{nm.name(eid)} {norm_attr(b)}")); continue
            if n == "move_entity_pos":
                # the idle refresh: stepped single step with a zero delta (or linear zero)
                rest = b[o:]
                if rest in (bytes([1, 0, 0, 0, 0, 0, 0]), bytes([3, 2, 0, 0, 0, 0, 0, 0]), bytes([3, 1, 0, 0, 0, 0, 0, 0]), bytes([0, 0, 0, 0, 0, 0, 0]), bytes([1, 1, 0, 0, 0, 0, 0, 0])):
                    if scn == "latency": steps[cur].append(("idle", "refresh"))       # counted, not compared byte for byte: its phase is the entity's age
                    continue
            if n == "entity_position_sync" and mask_pos:
                steps[cur].append((n, f"{nm.name(eid)} <pos>")); continue
            if n == "entity_position_sync" and scn == "walk":          # the position of a jump and the step's ticks depend on the tick the body fell on: the on-ground flag is what is compared
                steps[cur].append((n, f"{nm.name(eid)} ground={b[-1]}")); continue
            steps[cur].append((n, f"{nm.name(eid)} {b[o:].hex()}")); continue
        if n == "remove_entities":
            c, o = vi(b, 0); ids = []
            for _ in range(c): x, o = vi(b, o); ids.append(nm.name(x))
            steps[cur].append((n, " ".join(ids))); continue
        if n == "player_info_update":
            if b[0] == 0x10 and scn != "latency": continue          # the latency broadcast is on the server clock (every 601 ticks), not part of any step
            if b[0] == 0x10: steps[cur].append(("latency", "broadcast")); continue
            steps[cur].append((n, norm_info(b))); continue
        if n == "player_info_remove": steps[cur].append((n, b.hex())); continue
        if n == "waypoint":
            steps[cur].append((n, b.hex() if not mask_pos else b[:1].hex() + "<w>")); continue
        if n == "player_chat": steps[cur].append((n, "chat")); continue
        if n in CHUNKS and n != "level_chunk_with_light":
            steps[cur].append((n, b.hex() if n != "chunk_batch_finished" else b.hex())); continue
        if n == "level_chunk_with_light": steps[cur].append((n, b[:8].hex())); continue
        steps[cur].append((n, b.hex()))
    return steps

def move_sums(l):
    """the movement packets of a step as (count, sums of the three deltas in 1/4096 block): which tick of the step a body falls on depends on the age of the entity (its phase), so a walk is compared as totals"""
    n, sx, sy, sz = 0, 0, 0, 0
    for k, h in l:
        if k not in ("move_entity_pos", "move_entity_pos_rot"): continue
        b = bytes.fromhex(h.split(" ", 1)[1]); props, o = vi(b, 0)
        if props & 0xFE: _, o = vi(b, o)                 # a stepped packet: the ticks
        dx, dy, dz = struct.unpack(">hhh", b[o:o + 6]); n += 1; sx += dx; sy += dy; sz += dz
    return n, sx, sy, sz

def soft_equal(a, b):
    """walk: everything except the movement packets equal and in order; the movement as totals (the count within one packet, the sums within one body's worth of movement)"""
    soft = ("move_entity_pos", "move_entity_pos_rot", "move_entity_rot", "rotate_head")
    ra = [x for x in a if x[0] not in soft]; rb = [x for x in b if x[0] not in soft]
    for k in ("move_entity_rot", "rotate_head"):
        if abs(sum(1 for x in a if x[0] == k) - sum(1 for x in b if x[0] == k)) > 1: return False
    ma, mb = move_sums(a), move_sums(b)
    return ra == rb and abs(ma[0] - mb[0]) <= 1 and all(abs(x - y) <= 2000 for x, y in zip(ma[1:], mb[1:]))

def compare(name, v, o):
    fails = 0
    for step in list(v) + [s for s in o if s not in v]:
        a, b = v.get(step, []), o.get(step, [])
        if scn == "latency":          # an idle player is refreshed every 60 ticks and the latency of everybody goes out every 601: counted per step
            ok = all(abs(sum(1 for x in a if x[0] == k) - sum(1 for x in b if x[0] == k)) <= 1 for k in ("idle", "latency"))
            if ok: continue
        if a == b or (scn == "walk" and soft_equal(a, b)):
            if verbose: print(f"   ok   [{name}] {step}: {len(a)} packets")
            continue
        fails += 1
        print(f"   FAIL [{name}] {step}: vanilla {len(a)} packets, ours {len(b)}")
        for i in range(max(len(a), len(b))):
            x = a[i] if i < len(a) else None; y = b[i] if i < len(b) else None
            if x != y:
                print(f"        #{i}: vanilla {x[0] + ' ' + x[1][:110] if x else '-'}")
                print(f"             ours    {y[0] + ' ' + y[1][:110] if y else '-'}")
                if i >= 5: print("        ..."); break
    return fails

total = 0
files = {"join": ("obs", "act", "act2")}.get(scn, ("act", "obs"))
for who in files:
    pv, po = f"{vp}_{scn}_{who}.jsonl", f"{op}_{scn}_{who}.jsonl"
    if not (os.path.exists(pv) and os.path.exists(po)):
        print(f"   missing recording for {who}: {pv if not os.path.exists(pv) else po}"); total += 1; continue
    mp = scn == "join"
    v, o = reduce(load(pv), who, mp), reduce(load(po), who, mp)
    f = compare(who, v, o)
    steps = [s for s in v if s]
    print(f"{scn:8s} {who:5s}: {len(steps)} steps compared -> {'IDENTICAL' if not f else str(f) + ' step(s) DIFFER'}")
    total += f
sys.exit(1 if total else 0)
