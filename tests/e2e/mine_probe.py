#!/usr/bin/env python3
"""The mining protocol as two scripted clients see it (docs/MINING-AND-COMMANDS.md): "Surv" digs, "Obs" watches.  Run against the REAL vanilla 26.3 server to record and against a
dbcraft database to compare (tests/e2e/compare_mine.py).  Everything each client receives is recorded byte for byte; `mark`s name the steps.

usage: tests/e2e/mine_probe.py SCENARIO [--host 127.0.0.1] [--port 25961] [--out DIR/vanilla] [--dbcraft] [--list]
  SCENARIO  dig       a table of (block, tool) cases.  Per case: START_DESTROY_BLOCK, wait for exactly w-1 server ticks (counted by the level events 2019 / 2020 the server sends every
                      tick of a dig), STOP_DESTROY_BLOCK: refused (the block stays; the server finishes the dig itself, the "delayed destroy"); then again with w ticks: accepted.
                      w is the first tick count at which vanilla's rule  destroyProgress * (ticks + 1) >= 0.7  holds, computed here (float32) from the hardness table of
                      tools/gen_mining.sh and the tool rules of the item components
            misc      abort, a second START while digging, a STOP at another position, CHANGE_DESTROY_DIRECTION, a block out of reach, a block under another game mode, creative,
                      a sword in creative, a block mined while falling (not on the ground) and under water, an instantly mined block, an unbreakable block, a tool that breaks
            drops     blocks broken with and without the correct tool: the item entities that appear and the pickup (needs dbcraft.entity-mode = inline on dbcraft)
The server must run in survival, normal difficulty, a flat world with the surface at y = -61 (the floor the players stand on is y = -61), no mobs, "Surv" and "Obs" operators
(OPS=Surv,Obs tests/e2e/vanilla_start.sh).  --dbcraft: world edits go through psql (the PG* variables) instead of /setblock.  Writes <out>_<scenario>_surv.jsonl and _obs.jsonl.
"""
import argparse, json, os, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

REPORTS = os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports"))

def f32(x): return struct.unpack(">f", struct.pack(">f", x))[0]

# ---- the data the expected tick count is computed from (the jar's own numbers, written by tools/gen_mining.sh)
HARD, REQ = {}, {}
for line in open(os.path.join(REPORTS, "block_mining.tsv")):
    c = line.rstrip("\n").split("\t")
    if c[0] == "B": HARD[c[1]] = f32(float(c[2])); REQ[c[1]] = c[3] == "1"
def tool_rules(item):
    p = os.path.join(REPORTS, "item_components", item.split(":")[1] + ".json")
    if not os.path.exists(p): return None
    return json.load(open(p))["components"].get("minecraft:tool")

def psql(sql):
    subprocess.run(["psql", "-X", "-q", "-At", "-c", sql], check=True, capture_output=True)

def psql_out(sql):
    return subprocess.run(["psql", "-X", "-q", "-At", "-c", sql], check=True, capture_output=True, text=True).stdout.strip()

# the tick count w at which the server must accept the stop packet, from the jar's data (hardness, tool rules) and the block tags of the data pack (read with psql from the database that
# tools/load_datapack.py filled from a vanilla capture)
def plan_w(block, speed, correct, on_ground=True, water=False):
    h = HARD[block]
    if h < 0: return None
    f = f32(speed)
    if water: f = f32(f * f32(0.2))
    if not on_ground: f = f32(f / f32(5.0))
    i = 30 if (correct or not REQ[block]) else 100
    p = f32(f32(f / f32(h) if h else float("inf")) / f32(i)) if h else float("inf")
    if p >= 1.0: return 0
    j = 0
    while True:
        if f32(p * f32(j + 1)) >= f32(0.7): return j
        j += 1
        if j > 5000: return None

def tool_speed_correct(item, block):
    """Tool.getMiningSpeed / isCorrectForDrops against the jar's rules; tags come from the datapack tag files the loader read (tags.json written next to the reports by this probe's helper)"""
    t = tool_rules(item) if item else None
    if not t: return 1.0, False
    speed, correct = t.get("default_mining_speed", 1.0), None
    got_speed = False
    for r in t["rules"]:
        if not blocks_match(r["blocks"], block): continue
        if "speed" in r and not got_speed: speed = r["speed"]; got_speed = True
        if "correct_for_drops" in r and correct is None: correct = r["correct_for_drops"]
    return speed, bool(correct)

_tagmem = None
def blocks_match(spec, block):
    global _tagmem
    specs = spec if isinstance(spec, list) else [spec]
    for sp in specs:
        if sp.startswith("#"):
            if _tagmem is None:
                _tagmem = {}
                for line in subprocess.run(["psql", "-X", "-q", "-At", "-F", "|", "-c", "select tag, member from ref.dp_tag_member where registry = 'minecraft:block'"],
                                           check=True, capture_output=True, text=True).stdout.splitlines():
                    t, mem = line.split("|"); _tagmem.setdefault(t[len("minecraft:"):], set()).add(mem)
            if block in _tagmem.get(sp[len("#minecraft:"):], ()): return True
        elif sp == block: return True
    return False

ap = argparse.ArgumentParser()
ap.add_argument("scenario")
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25961)
ap.add_argument("--out", default="/dev/shm/mc_e2e/vanilla")
ap.add_argument("--name", default="Surv"); ap.add_argument("--observer", default="Obs")
ap.add_argument("--dbcraft", action="store_true", help="world edits with psql (PG* variables) instead of /setblock")
ap.add_argument("--only", default="", help="comma separated case names")
a = ap.parse_args()
os.makedirs(os.path.dirname(a.out), exist_ok=True)

X, Y, Z = 2, -60, 0                            # the block that is dug
def cmd(c, text): c.send("minecraft:chat_command", m.string(text))
def action(act, x, y, z, face, seq): return m.varint(act) + m.position(x, y, z) + bytes([face]) + m.varint(seq)
def sneak_tick(c): c.send("minecraft:client_tick_end"); c.send("minecraft:move_player_status_only", b"\x01")
def select(c, slot): c.send("minecraft:set_carried_item", struct.pack(">h", slot))

s = m.Client(a.host, a.port, a.name); o = m.Client(a.host, a.port, a.observer)
s.settle(1.0, 20.0); o.settle(1.0, 15.0)
for c in (s, o):
    c.send("minecraft:client_command", m.varint(0)); c.settle(0.5, 3.0)
def setblock(x, y, z, state):
    if a.dbcraft: psql("select mc.set_block('minecraft:overworld', %d, %d, %d, '%s')" % (x, y, z, state))
    else: cmd(s, "setblock %d %d %d %s" % (x, y, z, state))
def quiet(q=0.5, t=4.0): s.settle(q, t); o.settle(q, t)
def both(label): s.mark(label); o.mark(label)
def tickc(n=1):
    for _ in range(n): sneak_tick(s); time.sleep(0.05)

for nm in (a.name, a.observer): cmd(s, "gamemode survival " + nm)
cmd(s, "gamerule block_drops false"); cmd(s, "gamerule send_command_feedback false")
quiet(0.6, 3.0)
if a.dbcraft: psql("select mc.fill('minecraft:overworld', -3, -60, -3, 9, -50, 9, 'minecraft:air'), mc.fill('minecraft:overworld', -3, -61, -3, 9, -61, 9, 'minecraft:grass_block[snowy=false]')")
else: cmd(s, "fill -3 -60 -3 9 -50 9 minecraft:air"); cmd(s, "fill -3 -61 -3 9 -61 9 minecraft:grass_block")
cmd(s, "tp %s 0.5 -60 0.5" % a.name); cmd(s, "tp %s 0.5 -60 3.5" % a.observer); cmd(s, "clear %s" % a.name)
quiet(0.8, 4.0); tickc(6)
seq = [0]
def sq(): seq[0] += 1; return seq[0]

def n_events(c, k0):
    """digging events (level_event 2019 / 2020) the client has received since event index k0"""
    n = 0
    for e in c.since(k0, {"minecraft:level_event"}):
        if struct.unpack(">i", e["body"][:4])[0] in (2019, 2020): n += 1
    return n

def wait_events(n, k0, timeout=20.0):
    end = time.time() + timeout
    while time.time() < end:
        if n_events(s, k0) >= n: return True
        time.sleep(0.004)
    return False

def start(x=X, y=Y, z=Z, face=1): s.send("minecraft:player_action", action(0, x, y, z, face, sq()))
def stop(x=X, y=Y, z=Z, face=1): s.send("minecraft:player_action", action(3, x, y, z, face, sq()))
def abort(x=X, y=Y, z=Z, face=1): s.send("minecraft:player_action", action(2, x, y, z, face, sq()))
def change_dir(x=X, y=Y, z=Z, face=3): s.send("minecraft:player_action", action(1, x, y, z, face, 0))

def prepare(block, item, count=1, comp=None):
    setblock(X, Y, Z, block)
    cmd(s, "clear %s" % a.name)
    if item:
        cmd(s, "give %s %s%s" % (a.name, item, "" if count == 1 else " %d" % count))
    quiet(0.6, 3.0); select(s, 0); tickc(2)

def dig_case(name, block, item, why=""):
    base = block.split("[")[0]
    prepare(block, item)
    sp, correct = tool_speed_correct(item, base)
    w = plan_w(base, sp, correct)
    both("case %s w=%s" % (name, w))
    if w is None: return
    if w >= 1:
        both("%s: stop at %d ticks (too early)" % (name, w - 1))
        k0 = s.count(); start()
        if w - 1 > 0: wait_events(w - 1, k0)
        stop()
        if w <= 30: quiet(0.5, 25.0)                                      # the server finishes the dig itself (delayed destroy)
        else: quiet(0.3, 2.0); setblock(X, Y, Z, "minecraft:air"); quiet(0.5, 3.0)       # (a long dig: not waited for)
        setblock(X, Y, Z, block); quiet(0.5, 3.0)
    both("%s: stop at %d ticks (accepted)" % (name, w))
    k0 = s.count(); start()
    if w > 0: wait_events(w, k0)
    stop(); quiet(0.6, 5.0)
    both("%s: end" % name)

CASES = [
    # (name, block, tool)
    ("dirt_hand", "minecraft:dirt", None),
    ("dirt_shovel_wood", "minecraft:dirt", "minecraft:wooden_shovel"),
    ("dirt_shovel_iron", "minecraft:dirt", "minecraft:iron_shovel"),
    ("stone_hand", "minecraft:stone", None),
    ("stone_pick_wood", "minecraft:stone", "minecraft:wooden_pickaxe"),
    ("stone_pick_stone", "minecraft:stone", "minecraft:stone_pickaxe"),
    ("stone_pick_iron", "minecraft:stone", "minecraft:iron_pickaxe"),
    ("stone_pick_diamond", "minecraft:stone", "minecraft:diamond_pickaxe"),
    ("stone_pick_gold", "minecraft:stone", "minecraft:golden_pickaxe"),
    ("stone_pick_netherite", "minecraft:stone", "minecraft:netherite_pickaxe"),
    ("cobble_pick_wood", "minecraft:cobblestone", "minecraft:wooden_pickaxe"),
    ("iron_ore_pick_wood", "minecraft:iron_ore", "minecraft:wooden_pickaxe"),
    ("iron_ore_pick_stone", "minecraft:iron_ore", "minecraft:stone_pickaxe"),
    ("diamond_ore_pick_iron", "minecraft:diamond_ore", "minecraft:iron_pickaxe"),
    ("obsidian_pick_diamond", "minecraft:obsidian", "minecraft:diamond_pickaxe"),
    ("log_hand", "minecraft:oak_log[axis=y]", None),
    ("log_axe_wood", "minecraft:oak_log[axis=y]", "minecraft:wooden_axe"),
    ("log_axe_iron", "minecraft:oak_log[axis=y]", "minecraft:iron_axe"),
    ("planks_axe_diamond", "minecraft:oak_planks", "minecraft:diamond_axe"),
    ("planks_pick_iron", "minecraft:oak_planks", "minecraft:iron_pickaxe"),
    ("wool_hand", "minecraft:white_wool", None),
    ("wool_shears", "minecraft:white_wool", "minecraft:shears"),
    ("leaves_hand", "minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]", None),
    ("leaves_shears", "minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]", "minecraft:shears"),
    ("leaves_sword", "minecraft:oak_leaves[distance=1,persistent=true,waterlogged=false]", "minecraft:iron_sword"),
    ("cobweb_sword", "minecraft:cobweb", "minecraft:iron_sword"),
    ("cobweb_shears", "minecraft:cobweb", "minecraft:shears"),
    ("cobweb_hand", "minecraft:cobweb", None),
    ("glass_hand", "minecraft:glass", None),
    ("sand_shovel_diamond", "minecraft:sand", "minecraft:diamond_shovel"),
    ("snow_block_shovel", "minecraft:snow_block", "minecraft:iron_shovel"),
    ("netherrack_pick_wood", "minecraft:netherrack", "minecraft:wooden_pickaxe"),
    ("hay_hoe", "minecraft:hay_block[axis=y]", "minecraft:diamond_hoe"),
    ("deepslate_pick_iron", "minecraft:deepslate[axis=y]", "minecraft:iron_pickaxe"),
    ("ladder_hand", "minecraft:ladder[facing=north,waterlogged=false]", None),
    ("torch_hand", "minecraft:torch", None),
    ("short_grass_hand", "minecraft:short_grass", None),
    ("bedrock_pick", "minecraft:bedrock", "minecraft:diamond_pickaxe"),
    ("stone_sword", "minecraft:stone", "minecraft:iron_sword"),
]

if a.scenario == "dig":
    only = set(filter(None, a.only.split(",")))
    for (nm, blk, tool) in CASES:
        if only and nm not in only: continue
        if blk.endswith("bedrock") or nm == "bedrock_pick": continue
        try: dig_case(nm, blk, tool)
        except subprocess.CalledProcessError as e: print("case %s: %s" % (nm, e.stderr.decode()[:200] if e.stderr else e)); both("case %s failed" % nm)
elif a.scenario == "misc":
    # --- abort: the crack disappears for the observer
    prepare("minecraft:stone", "minecraft:iron_pickaxe")
    both("abort: start, 5 ticks, abort"); k0 = s.count(); start(); wait_events(5, k0); abort(); quiet(0.6, 3.0)
    # --- after the abort a stop packet does nothing (the dig is over)
    both("abort: then stop"); stop(); quiet(0.6, 3.0)
    # --- a STOP without a START in this tick window: the block stays
    both("stop without start"); stop(); quiet(0.6, 3.0)
    # --- second START while digging another block: the server says what the first one looks like again (block_update), then digs the new one
    setblock(X, Y, Z + 1, "minecraft:stone"); quiet(0.4, 2.0)
    both("start A, start B"); k0 = s.count(); start(X, Y, Z); wait_events(3, k0); start(X, Y, Z + 1); wait_events(8, k0); abort(X, Y, Z + 1); quiet(0.6, 3.0)
    # --- stop at another position than the one dug
    both("stop at another position"); k0 = s.count(); start(X, Y, Z); wait_events(40, k0); stop(X, Y, Z + 1); quiet(0.6, 3.0); abort(X, Y, Z); quiet(0.4, 2.0)
    # --- change destroy direction (sequence 0), then keep digging: the events carry the new direction
    both("change direction"); k0 = s.count(); start(X, Y, Z, 1); wait_events(2, k0); change_dir(X, Y, Z, 3); wait_events(6, k0); abort(); quiet(0.6, 3.0)
    # --- a block out of reach: nothing, the ack only
    setblock(X + 7, Y, Z, "minecraft:stone"); quiet(0.4, 2.0)
    both("out of reach: start, stop"); start(X + 7, Y, Z); tickc(3); stop(X + 7, Y, Z); quiet(0.6, 3.0)
    both("out of reach: abort while digging"); k0 = s.count(); start(X, Y, Z); wait_events(2, k0); abort(X + 7, Y, Z); quiet(0.6, 3.0); abort(X, Y, Z); quiet(0.4, 2.0)
    # --- adventure and spectator
    for gm in ("adventure", "spectator"):
        cmd(s, "gamemode %s %s" % (gm, a.name)); quiet(0.6, 3.0)
        both("%s: start" % gm); start(); tickc(3); stop(); quiet(0.6, 3.0)
    # --- creative: the block goes at once; with a sword nothing happens (block_update restores it)
    cmd(s, "gamemode creative %s" % a.name); quiet(0.6, 3.0)
    both("creative: start"); start(); quiet(0.6, 3.0)
    prepare("minecraft:stone", "minecraft:iron_sword")
    both("creative sword: start"); start(); quiet(0.6, 3.0)
    prepare("minecraft:bedrock", None)
    both("creative bedrock: start"); start(); quiet(0.6, 3.0)
    setblock(X, Y, Z, "minecraft:command_block[conditional=false,facing=north]"); quiet(0.4, 2.0)
    both("creative command block: start"); start(); quiet(0.6, 3.0)
    cmd(s, "gamemode survival %s" % a.name); quiet(0.6, 3.0)
    # --- instantly mined blocks (progress >= 1 at once): grass, a torch, a plant
    for nm, blk in (("short_grass", "minecraft:short_grass"), ("torch", "minecraft:torch")):
        prepare(blk, None); both("instant %s" % nm); start(); quiet(0.6, 3.0)
    # --- unbreakable in survival: bedrock never gets progress
    prepare("minecraft:bedrock", "minecraft:diamond_pickaxe")
    both("bedrock: start, 10 ticks, stop"); k0 = s.count(); start(); wait_events(10, k0); stop(); quiet(0.6, 3.0); abort(); quiet(0.4, 2.0)
    # --- fast diggers: a stone block that a netherite pickaxe with haste would break at once is not available; efficiency is not modelled (no enchantments)
    # --- falling (not on the ground): speed / 5
    prepare("minecraft:dirt", "minecraft:iron_shovel")
    cmd(s, "tp %s 0.5 -55 0.5" % a.name); s.settle(0.3, 1.0)
    both("dirt, off the ground"); w = None
    k0 = s.count(); start(); wait_events(3, k0); stop(); quiet(0.5, 3.0); abort(); quiet(0.4, 2.0)
    cmd(s, "tp %s 0.5 -60 0.5" % a.name); quiet(0.8, 3.0); tickc(4)
elif a.scenario == "pending":
    pass
else:
    sys.exit("unknown scenario")
s.dump("%s_%s_surv.jsonl" % (a.out, a.scenario)); o.dump("%s_%s_obs.jsonl" % (a.out, a.scenario))
print("recorded %s_%s_{surv,obs}.jsonl" % (a.out, a.scenario))
s.close(); o.close()
