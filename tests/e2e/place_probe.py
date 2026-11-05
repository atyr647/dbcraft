#!/usr/bin/env python3
"""Block placement states: what a player gets when it places a block (BlockItem.getStateForPlacement).  One creative operator "Surv" stands at a fixed place and
places items against an anchor block with chosen yaw, pitch, face and cursor position; every block change the server sends back is recorded as {position: state id}.
Run against the REAL vanilla server (RCON resets and prepares the area) and against a dbcraft database (psql does it) and compare with tests/e2e/compare_place.py.

usage: tests/e2e/place_probe.py vanilla --port P --rcon R --out FILE        (a vanilla server as tests/e2e/vanilla_start.sh makes it, OPS=Surv)
       tests/e2e/place_probe.py dbcraft --port P --out FILE                 (PGHOST/PGPORT/PGDATABASE name the database; "Surv" must be an operator there)
       [--only FAMILY[,FAMILY]] [--limit N]
Every case: clear the box around the target, build the anchor and the neighbours the case names (setblock), put the item in the hand, turn to (yaw, pitch), send
use_item_on on the anchor's face with the cursor, wait until the server is quiet.  The anchor is at (11, -58, 10); the player at (11.5, -60, 6.5).
"""
import argparse, json, os, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["vanilla", "dbcraft"])
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, required=True)
ap.add_argument("--rcon", type=int, default=0); ap.add_argument("--out", required=True)
ap.add_argument("--only", default=""); ap.add_argument("--limit", type=int, default=0)
ap.add_argument("--name", default="Surv")
a = ap.parse_args()

AX, AY, AZ = 11, -58, 10                  # the anchor block
PX, PY, PZ = 11.5, -60.0, 6.5             # the player
FACES = {"down": (0, (0, -1, 0)), "up": (1, (0, 1, 0)), "north": (2, (0, 0, -1)), "south": (3, (0, 0, 1)), "west": (4, (-1, 0, 0)), "east": (5, (1, 0, 0))}
FREE = ["minecraft:oak_log", "minecraft:hay_block", "minecraft:quartz_pillar", "minecraft:bone_block", "minecraft:iron_chain", "minecraft:stripped_oak_wood", "minecraft:purpur_pillar"]
FACING_FAMILY = ["minecraft:furnace", "minecraft:blast_furnace", "minecraft:smoker", "minecraft:stonecutter", "minecraft:loom", "minecraft:lectern", "minecraft:carved_pumpkin",
                 "minecraft:white_glazed_terracotta", "minecraft:anvil", "minecraft:campfire", "minecraft:oak_fence_gate", "minecraft:repeater", "minecraft:comparator",
                 "minecraft:chest", "minecraft:ender_chest", "minecraft:trapped_chest", "minecraft:bell"]
DIRECTIONAL = ["minecraft:dispenser", "minecraft:dropper", "minecraft:observer", "minecraft:piston", "minecraft:sticky_piston", "minecraft:barrel", "minecraft:command_block"]

def cases():
    out = []
    def add(fam, item, face, cursor=(0.5, 0.5, 0.5), yaw=0.0, pitch=0.0, anchor="minecraft:stone", setup=(), sneak=False, desc=""):
        out.append(dict(family=fam, item=item, face=face, cursor=cursor, yaw=yaw, pitch=pitch, anchor=anchor, setup=list(setup), sneak=sneak, desc=desc))
    for it in FREE:
        for f in FACES: add("pillar", it, f, desc="%s %s" % (it, f))
    for f in ("up", "down", "north", "east"):
        for cy in (0.25, 0.75):
            add("slab", "minecraft:oak_slab", f, cursor=(0.5, cy, 0.5), desc="slab %s y=%s" % (f, cy))
    add("slab", "minecraft:stone_slab", "up", desc="stone slab up")
    # merging: the anchor IS a slab
    add("slab", "minecraft:oak_slab", "up", anchor="minecraft:oak_slab[type=bottom,waterlogged=false]", desc="merge: top of a bottom slab")
    add("slab", "minecraft:oak_slab", "down", anchor="minecraft:oak_slab[type=top,waterlogged=false]", desc="merge: bottom of a top slab")
    add("slab", "minecraft:oak_slab", "north", cursor=(0.5, 0.75, 0.0), anchor="minecraft:oak_slab[type=bottom,waterlogged=false]", desc="merge: side of a bottom slab, upper half")
    add("slab", "minecraft:oak_slab", "north", cursor=(0.5, 0.25, 0.0), anchor="minecraft:oak_slab[type=bottom,waterlogged=false]", desc="no merge: side of a bottom slab, lower half")
    add("slab", "minecraft:oak_slab", "north", cursor=(0.5, 0.25, 0.0), anchor="minecraft:oak_slab[type=top,waterlogged=false]", desc="merge: side of a top slab, lower half")
    add("slab", "minecraft:oak_slab", "up", anchor="minecraft:oak_slab[type=top,waterlogged=false]", desc="no merge: top of a top slab")
    add("slab", "minecraft:stone_slab", "up", anchor="minecraft:oak_slab[type=bottom,waterlogged=false]", desc="no merge: another slab")
    for yaw in (0.0, 90.0, 180.0, 270.0, 30.0, -135.0):
        for f, cy in (("up", 0.5), ("down", 0.5), ("north", 0.25), ("north", 0.75)):
            add("stairs", "minecraft:oak_stairs", f, cursor=(0.5, cy, 0.5), yaw=yaw, desc="stairs yaw %s %s y=%s" % (yaw, f, cy))
    # corner shapes: neighbours that are stairs (the target is (11,-57,10): above the anchor)
    for yaw in (0.0, 90.0, 180.0, 270.0):
        for nb_off, nb_face in (((0, 0, -1), "east"), ((0, 0, -1), "west"), ((0, 0, 1), "east"), ((0, 0, 1), "west"), ((1, 0, 0), "north"), ((1, 0, 0), "south"), ((-1, 0, 0), "north"), ((-1, 0, 0), "south")):
            add("stairs", "minecraft:oak_stairs", "up", yaw=yaw,
                setup=[((AX + nb_off[0], AY + 1 + nb_off[1], AZ + nb_off[2]), "minecraft:oak_stairs[facing=%s,half=bottom,shape=straight,waterlogged=false]" % nb_face)],
                desc="stairs corner yaw %s neighbour %s %s" % (yaw, nb_off, nb_face))
    for it in FACING_FAMILY:
        for yaw in (0.0, 90.0, 180.0, 270.0, 45.0, -30.0):
            add("facing", it, "up", yaw=yaw, desc="%s yaw %s" % (it, yaw))
    for it in DIRECTIONAL:
        for yaw in (0.0, 90.0, 180.0, 270.0):
            for pitch in (0.0, 70.0, -70.0):
                add("directional", it, "up", yaw=yaw, pitch=pitch, desc="%s yaw %s pitch %s" % (it, yaw, pitch))
    for f in FACES: add("directional", "minecraft:hopper", f, desc="hopper %s" % f)
    for f in FACES:
        for cy in (0.25, 0.75):
            for yaw in (0.0, 90.0):
                add("trapdoor", "minecraft:oak_trapdoor", f, cursor=(0.5, cy, 0.5), yaw=yaw, desc="trapdoor %s y=%s yaw %s" % (f, cy, yaw))
    for it in ("minecraft:oak_sign", "minecraft:white_banner", "minecraft:skeleton_skull"):
        for yaw in (0.0, 22.5, 45.0, 90.0, 135.0, 200.0, 270.0, -45.0):
            add("sign", it, "up", yaw=yaw, desc="%s yaw %s up" % (it, yaw))
        for f in ("north", "south", "west", "east", "down"):
            add("sign", it, f, desc="%s %s" % (it, f))
    for it in ("minecraft:torch", "minecraft:redstone_torch", "minecraft:soul_torch", "minecraft:lantern", "minecraft:ladder", "minecraft:lever", "minecraft:stone_button", "minecraft:oak_button"):
        for f in FACES:
            for yaw in (0.0, 90.0):
                add("attached", it, f, yaw=yaw, desc="%s %s yaw %s" % (it, f, yaw))
    # connections of fences, walls and panes: the target is (11,-57,10); neighbours on its four sides
    nbs = {"n": (0, 0, -1), "s": (0, 0, 1), "w": (-1, 0, 0), "e": (1, 0, 0)}
    combos = [("n",), ("n", "e"), ("n", "s"), ("w", "e"), ("n", "s", "w", "e")]
    for it, same in (("minecraft:oak_fence", "minecraft:oak_fence[east=false,north=false,south=false,waterlogged=false,west=false]"),
                     ("minecraft:glass_pane", "minecraft:glass_pane[east=false,north=false,south=false,waterlogged=false,west=false]"),
                     ("minecraft:iron_bars", "minecraft:iron_bars[east=false,north=false,south=false,waterlogged=false,west=false]"),
                     ("minecraft:cobblestone_wall", "minecraft:cobblestone_wall[east=none,north=none,south=none,up=true,waterlogged=false,west=none]")):
        for combo in combos:
            add("connect", it, "up", setup=[((AX + nbs[k][0], AY + 1, AZ + nbs[k][2]), same) for k in combo], desc="%s with neighbours %s" % (it, "".join(combo)))
        add("connect", it, "up", setup=[((AX + 1, AY + 1, AZ), "minecraft:stone")], desc="%s with a stone block east" % it)
        add("connect", it, "up", setup=[((AX, AY + 1, AZ - 1), "minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]")], desc="%s with stairs north" % it)
    add("connect", "minecraft:oak_fence", "up", setup=[((AX, AY + 1, AZ - 1), "minecraft:oak_fence_gate[facing=east,in_wall=false,open=false,powered=false]")], desc="fence with a gate facing east, north of it")
    add("connect", "minecraft:oak_fence", "up", setup=[((AX, AY + 1, AZ - 1), "minecraft:oak_fence_gate[facing=north,in_wall=false,open=false,powered=false]")], desc="fence with a gate facing north, north of it")
    add("connect", "minecraft:oak_fence", "up", setup=[((AX, AY + 1, AZ - 1), "minecraft:stone_slab[type=bottom,waterlogged=false]")], desc="fence with a bottom slab north of it")
    add("connect", "minecraft:nether_brick_fence", "up", setup=[((AX, AY + 1, AZ - 1), "minecraft:oak_fence[east=false,north=false,south=false,waterlogged=false,west=false]")], desc="a nether brick fence next to a wooden fence")
    for it in ("minecraft:oak_door", "minecraft:iron_door"):
        for yaw in (0.0, 90.0, 180.0, 270.0):
            add("door", it, "up", yaw=yaw, desc="%s yaw %s" % (it, yaw))
        add("door", it, "up", yaw=0.0, setup=[((AX - 1, AY + 1, AZ), "minecraft:oak_door[facing=north,half=lower,hinge=left,open=false,powered=false]"), ((AX - 1, AY + 2, AZ), "minecraft:oak_door[facing=north,half=upper,hinge=left,open=false,powered=false]")], desc="%s next to a door (west)" % it)
        add("door", it, "up", yaw=0.0, setup=[((AX + 1, AY + 1, AZ), "minecraft:oak_door[facing=north,half=lower,hinge=left,open=false,powered=false]"), ((AX + 1, AY + 2, AZ), "minecraft:oak_door[facing=north,half=upper,hinge=left,open=false,powered=false]")], desc="%s next to a door (east)" % it)
    if a.only: out = [c for c in out if c["family"] in a.only.split(",")]
    if a.limit: out = out[:a.limit]
    return out

rc = None
if a.mode == "vanilla":
    import common as C
    rc = C.Rcon(port=a.rcon, pw="dbcraft-e2e")

def sql(q):
    subprocess.run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", q], check=True, capture_output=True)

def parse_state(s):
    b, _, rest = s.partition("[")
    return b, dict(kv.split("=") for kv in rest.rstrip("]").split(",")) if rest else {}

def server_reset(c):
    x1, y1, z1, x2, y2, z2 = AX - 3, AY - 2, AZ - 3, AX + 3, AY + 4, AZ + 3
    blocks = [((AX, AY, AZ), c["anchor"])] + c["setup"]
    if rc:
        rc.cmd("fill %d %d %d %d %d %d minecraft:air" % (x1, y1, z1, x2, y2, z2))
        for (x, y, z), st in blocks: rc.cmd("setblock %d %d %d %s" % (x, y, z, st))
    else:
        q = "select mc.fill('minecraft:overworld', %d, %d, %d, %d, %d, %d, 'minecraft:air');" % (x1, y1, z1, x2, y2, z2)
        for (x, y, z), st in blocks:
            b, props = parse_state(st)
            if props: st = "(select mc.state_with('%s', '%s'))" % (b, ",".join("%s=%s" % kv for kv in props.items()))
            else: st = "'%s'" % st
            q += "select mc.set_block('minecraft:overworld', %d, %d, %d, %s);" % (x, y, z, st)
        sql(q)

def decode_updates(events, k):
    """{(x,y,z): state id} of every block_update / section_blocks_update received after event index k"""
    res = {}
    for e in events[k:]:
        if e["state"] == "mark" or e["dir"] != "clientbound": continue
        n = e["name"]
        if n == "minecraft:block_update":
            x, y, z = m.unposition(e["body"], 0); sid, _ = m.parse_varint(e["body"], 8); res[(x, y, z)] = sid
        elif n == "minecraft:section_blocks_update":
            v = struct.unpack(">q", e["body"][:8])[0]; sx = v >> 42; sz = (v >> 20) & 0x3FFFFF; sy = v & 0xFFFFF      # SectionPos: x 22 bits | z 22 bits | y 20 bits, all signed
            if sz >= 1 << 21: sz -= 1 << 22
            if sy >= 1 << 19: sy -= 1 << 20
            cnt, o = m.parse_varint(e["body"], 8)
            for _ in range(cnt):
                val = 0; sh = 0
                while True:
                    b = e["body"][o]; o += 1; val |= (b & 0x7f) << sh
                    if not b & 0x80: break
                    sh += 7
                res[(sx * 16 + ((val >> 8) & 15), sy * 16 + (val & 15), sz * 16 + ((val >> 4) & 15))] = val >> 12
    return res

c = m.Client(a.host, a.port, a.name)
c.settle(1.0, 20.0)
def cmd(t): c.send("minecraft:chat_command", m.string(t))
def tick(n=1):
    for _ in range(n): c.send("minecraft:client_tick_end"); time.sleep(0.05)
cmd("gamemode creative %s" % a.name); c.settle(0.5, 3.0)
cmd("tp %s %s %s %s" % (a.name, PX, PY, PZ)); c.settle(0.8, 4.0); tick(4)
results = []
t0 = time.time()
for i, case in enumerate(cases()):
    server_reset(case)
    time.sleep(0.12); c.settle(0.15, 1.0)
    c.send("minecraft:set_creative_mode_slot", m.i16(36) + m.stack(case["item"], 1)); c.send("minecraft:set_carried_item", struct.pack(">h", 0)); tick(2)
    c.send("minecraft:move_player_rot", struct.pack(">ffB", case["yaw"], case["pitch"], 1)); tick(2)
    if case["sneak"]: pass
    k = len(c.events)
    fid, (dx, dy, dz) = FACES[case["face"]]
    cx, cy, cz = case["cursor"]
    c.send("minecraft:use_item_on", m.varint(0) + m.position(AX, AY, AZ) + m.varint(fid) + struct.pack(">fff", cx, cy, cz) + b"\x00\x00" + m.varint(i + 1))
    tick(2); c.settle(0.2, 2.0)
    upd = decode_updates(c.events, k)
    results.append(dict(i=i, family=case["family"], item=case["item"], desc=case["desc"], face=case["face"], yaw=case["yaw"], pitch=case["pitch"], cursor=case["cursor"],
                        anchor=case["anchor"], setup=[[list(p), s] for p, s in case["setup"]], updates={"%d,%d,%d" % p: s for p, s in sorted(upd.items())}))
    if i % 50 == 0: print("case %d  %.0fs" % (i, time.time() - t0), flush=True)
json.dump(results, open(a.out, "w"), indent=0)
print("recorded %d cases in %.0f s: %s" % (len(results), time.time() - t0, a.out))
c.close()
