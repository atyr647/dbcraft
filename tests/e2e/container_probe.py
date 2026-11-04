#!/usr/bin/env python3
"""Container click sequences as one client sees them.  The same scripted client runs against the REAL vanilla 26.3 server (blocks and items prepared over RCON) and against
a dbcraft database (the same preparation through SQL), every container packet it receives is reduced to a readable tuple, and tests/e2e/compare_container.py compares the two.

usage:
  vanilla:  container_probe.py --mode vanilla --port 25881 --rcon 25885 --rcon-pw dbcraft-cont --scenario inv --seed 1 --steps 40 --out /tmp/x/vanilla_inv_1.json
  dbcraft:  container_probe.py --mode dbcraft --port 25887 --psql 'psql -X -At -h /tmp -p 55467 -U postgres dbcraft' --actions /tmp/x/vanilla_inv_1.json --out /tmp/x/ours_inv_1.json
Without --actions the actions are generated from --seed (using what the server answered to choose meaningful clicks); with --actions they are replayed exactly.

What the harness does for every step: send the click with the state id the client last saw and EMPTY claims (no changed slots, an empty carried item: the server must therefore
report every slot and the cursor that the click changed), wait, then send a harmless click with a stale state id (PICKUP on slot -1), to which the server answers with the
whole menu (container_set_content): the full state after every step.  The packets between the two are the click's own answer.
`--claims` makes the click claim the effect the first (vanilla) run showed instead, which is what a real client does (changedSlots with hashes of what it predicted).
"""
import argparse, json, os, random, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
import mcclient as m

ITEM_NAME = {v: k for k, v in m.ITEM.items()}
PALETTE = {  # item: max stack
    "minecraft:oak_log": 64, "minecraft:oak_planks": 64, "minecraft:stick": 64, "minecraft:cobblestone": 64, "minecraft:iron_ingot": 64, "minecraft:coal": 64,
    "minecraft:bucket": 16, "minecraft:water_bucket": 1, "minecraft:milk_bucket": 1, "minecraft:iron_sword": 1, "minecraft:iron_helmet": 1, "minecraft:iron_chestplate": 1,
    "minecraft:leather_boots": 1, "minecraft:shield": 1, "minecraft:string": 64, "minecraft:sand": 64, "minecraft:snowball": 16, "minecraft:ender_pearl": 16,
    "minecraft:white_wool": 64, "minecraft:diamond_leggings": 1,
}


def pv(b, o):
    return m.parse_varint(b, o)


def stack_str(b, o):
    n, o = pv(b, o)
    if n == 0:
        return None, o
    iid, o = pv(b, o)
    added, o = pv(b, o)
    removed, o = pv(b, o)
    if added or removed:
        raise ValueError("stack with components")
    return [ITEM_NAME.get(iid, iid).replace("minecraft:", ""), n], o


def reduce_packet(e):
    """a clientbound container packet as a plain list, or None"""
    b = e["body"]
    nm = e["name"].replace("minecraft:", "")
    if nm == "container_set_slot":
        cid, o = pv(b, 0); st, o = pv(b, o); slot = struct.unpack(">h", b[o:o + 2])[0]; s, o = stack_str(b, o + 2)
        return ["set_slot", cid, st, slot, s]
    if nm == "container_set_content":
        cid, o = pv(b, 0); st, o = pv(b, o); n, o = pv(b, o); items = []
        for _ in range(n):
            s, o = stack_str(b, o); items.append(s)
        car, o = stack_str(b, o)
        return ["set_content", cid, st, items, car]
    if nm == "set_cursor_item":
        s, o = stack_str(b, 0); return ["cursor", s]
    if nm == "set_player_inventory":
        slot, o = pv(b, 0); s, o = stack_str(b, o); return ["inv", slot, s]
    if nm == "open_screen":
        cid, o = pv(b, 0); t, o = pv(b, o); return ["open", cid, t, b[o:].hex()]
    if nm == "container_close":
        cid, o = pv(b, 0); return ["close", cid]
    if nm == "container_set_data":
        cid, o = pv(b, 0); i, v = struct.unpack(">hh", b[o:o + 4]); return ["data", cid, i, v]
    if nm == "block_event":
        return ["block_event", list(m.unposition(b, 0)), b[8], b[9], pv(b, 10)[0]]
    if nm == "block_update":
        return ["block_update", list(m.unposition(b, 0)), pv(b, 8)[0]]
    return None


KINDS = ("container_set_slot", "container_set_content", "set_cursor_item", "set_player_inventory", "open_screen", "container_close", "container_set_data", "block_event", "block_update")


def collect(c, k):
    out = []
    for e in c.since(k, {"minecraft:" + x for x in KINDS}):
        r = reduce_packet(e)
        if r:
            out.append(r)
    return out


def hashed(stack):
    """HashedStack of a component-free stack"""
    if stack is None:
        return b"\x00"
    return b"\x01" + m.varint(m.ITEM["minecraft:" + stack[0]]) + m.varint(stack[1]) + m.varint(0) + m.varint(0)


class Probe:
    def __init__(self, a):
        self.a = a
        self.rc = None
        if a.mode == "vanilla":
            import common as C
            self.rc = C.Rcon(port=a.rcon, pw=a.rcon_pw)
        self.c = None
        self.cid = 0
        self.state = 1
        self.states = {0: 1}    # container id -> the state id the client last saw for it
        self.menu = {}          # slot -> [item, n] as the client believes
        self.carried = None

    # ---- server side preparation (commands over RCON for vanilla, SQL for dbcraft)
    def sql(self, q):
        r = subprocess.run(self.a.psql.split() + ["-c", q], capture_output=True, text=True)
        if r.returncode:
            print("SQL ERROR", r.stderr, q[:200])
        return r.stdout.strip()

    def cmd(self, text):
        if self.rc:
            return self.rc.cmd(text)
        return None

    def connect(self):
        if self.c:
            self.c.close()
            time.sleep(0.6)
        self.c = m.Client("127.0.0.1", self.a.port, self.a.name)
        self.c.settle(1.0, 15.0)
        self.cid, self.state = 0, 1
        self.states = {0: 1}
        self.sync_from(0)

    def sync_from(self, k):
        """update the client's belief (state id, container id, slots, cursor) from what has arrived since event k"""
        for e in self.c.since(k):
            try:
                r = reduce_packet(e) if e["name"].replace("minecraft:", "") in KINDS else None
            except ValueError:
                r = None
            if not r:
                continue
            if r[0] == "open":
                self.cid = r[1]; self.menu = {}; self.carried = None; self.states[self.cid] = 0
            elif r[0] == "close":
                self.to_inventory()
            elif r[0] == "set_content":
                self.states[r[1]] = r[2]
                if r[1] == self.cid:
                    self.menu = {i: s for i, s in enumerate(r[3])}; self.carried = r[4]
                self.state = self.states.get(self.cid, self.state)
            elif r[0] == "set_slot":
                self.states[r[1]] = r[2]
                if r[1] == self.cid:
                    self.menu[r[3]] = r[4]
                self.state = self.states.get(self.cid, self.state)
            elif r[0] == "cursor":
                self.carried = r[1]

    def to_inventory(self):
        """the inventory menu is the open one again: the client's picture of it is rebuilt by the next full-state dump"""
        self.cid = 0
        self.state = self.states.get(0, 1)

    def send_click(self, slot, button, inp, state=None, changed=None, carried=None):
        body = m.varint(self.cid) + m.varint(self.state if state is None else state) + struct.pack(">h", slot) + struct.pack(">b", button) + m.varint(inp)
        changed = changed or {}
        body += m.varint(len(changed))
        for s, st in changed.items():
            body += struct.pack(">h", s) + hashed(st)
        body += hashed(carried)
        self.c.send("minecraft:container_click", body)

    def settle(self, t=0.16):
        time.sleep(t)

    def reset_player(self, stacks):
        """a known inventory (verified: a loaded machine can answer the game mode change late and drop the creative slots, so it retries)"""
        for attempt in range(5):
            self.reset_player_once(stacks)
            want = {s: (it.replace("minecraft:", ""), n) for s, (it, n) in stacks.items()}
            have = {s: (v[0], v[1]) for s, v in self.menu.items() if 5 <= s <= 45 and v}
            if have == want:
                return
            print("reset_player: inventory not as planned (attempt %d), again; differs in %s" % (attempt + 1, {s: (want.get(s), have.get(s)) for s in sorted(set(want) | set(have)) if want.get(s) != have.get(s)}), file=sys.stderr)
        raise SystemExit("reset_player: the inventory never matched the plan")

    def reset_player_once(self, stacks):
        """close any screen (the grid goes back into the inventory), creative: clear 5..45, set the stacks, back to survival"""
        c = self.c
        c.send("minecraft:container_close", m.varint(0)); self.settle(0.3)
        self.say("gamemode creative"); self.settle(0.4)
        for s in range(5, 46):
            c.send("minecraft:set_creative_mode_slot", struct.pack(">h", s) + b"\x00")
        for s, (item, n) in stacks.items():
            c.send("minecraft:set_creative_mode_slot", struct.pack(">h", s) + m.stack(item, n))
        self.settle(0.5)
        self.say("gamemode survival"); self.settle(0.5)
        k = c.count()
        self.send_click(-1, 0, 0, state=(self.state + 20000) & 32767)   # a stale click: the whole menu, so that the harness knows what the server has
        for _ in range(80):                                            # (a loaded machine answers late: wait for the answer)
            time.sleep(0.1)
            if self.c.since(k, {"minecraft:container_set_content"}):
                break
        self.settle(0.3)
        self.sync_from(k)

    def say(self, text):
        if self.a.mode == "vanilla":
            self.c.send("minecraft:chat_command", m.string(text))
        else:
            self.c.send("minecraft:chat_command", m.string(text))


CRAFT = ["minecraft:oak_log", "minecraft:oak_planks", "minecraft:stick", "minecraft:string", "minecraft:sand", "minecraft:snowball", "minecraft:iron_ingot",
         "minecraft:cobblestone", "minecraft:coal", "minecraft:water_bucket", "minecraft:milk_bucket", "minecraft:white_wool", "minecraft:red_dye", "minecraft:white_dye"]
CRAFT_MAX = {"minecraft:water_bucket": 1, "minecraft:milk_bucket": 1, "minecraft:snowball": 16}


def gen_stacks(rnd, scenario="inv"):
    if scenario in ("craft", "table"):
        stacks = {}
        for s in list(range(9, 45)):
            if rnd.random() < 0.7:
                it = rnd.choice(CRAFT); mx = CRAFT_MAX.get(it, 64)
                stacks[s] = (it, rnd.randint(1, mx) if rnd.random() < 0.6 else rnd.randint(1, min(5, mx)))
        return stacks
    items = list(PALETTE)
    stacks = {}
    for s in list(range(9, 45)) + [45]:
        if rnd.random() < 0.45:
            it = rnd.choice(items)
            stacks[s] = (it, rnd.randint(1, PALETTE[it]) if rnd.random() < 0.7 else rnd.randint(1, min(4, PALETTE[it])))
    for s, it in ((5, "minecraft:iron_helmet"), (6, "minecraft:iron_chestplate")):
        if rnd.random() < 0.3:
            stacks[s] = (it, 1)
    return stacks


def gen_action(rnd, p, scenario="inv"):
    """choose the next click from what the client believes the menu holds"""
    filled = [s for s, v in p.menu.items() if v]
    n_slots = max(p.menu) + 1 if p.menu else 46
    if scenario in ("craft", "table") and rnd.random() < 0.6:
        # crafting-heavy: pick up a stack, put single items into grid cells, take the result (click, shift-click, hotbar swap)
        grid = list(range(1, 5)) if scenario == "craft" else list(range(1, 10))
        r = rnd.random()
        if r < 0.30:
            return {"op": "click", "slot": rnd.choice(filled) if filled else 9, "button": rnd.randint(0, 1), "input": 0}
        if r < 0.62:
            return {"op": "click", "slot": rnd.choice(grid), "button": rnd.choice([0, 1, 1]), "input": 0}
        if r < 0.78:
            return {"op": "click", "slot": 0, "button": rnd.randint(0, 1), "input": rnd.choice([0, 0, 1, 1, 6])}
        if r < 0.86:
            return {"op": "click", "slot": rnd.choice(grid + [0]), "button": rnd.choice([0, 1]), "input": 1}
        if r < 0.92:
            return {"op": "click", "slot": rnd.choice(grid + [0]), "button": rnd.choice([0, 1, 2, 3, 40]), "input": 2}
        typ = rnd.randint(0, 1)
        return {"op": "drag", "type": typ, "slots": rnd.sample(grid + [rnd.choice(filled) if filled else 9], min(3, len(grid)))}
    r = rnd.random()
    slot = rnd.choice(filled) if filled and rnd.random() < 0.75 else rnd.randrange(0, n_slots)
    grid = [1, 2, 3, 4] if n_slots == 46 and p.cid == 0 else list(range(1, 10)) if p.cid else []
    if grid and rnd.random() < 0.25:
        slot = rnd.choice(grid)
    if r < 0.40:
        return {"op": "click", "slot": slot, "button": rnd.randint(0, 1), "input": 0}
    if r < 0.55:
        return {"op": "click", "slot": slot, "button": rnd.randint(0, 1), "input": 1}
    if r < 0.67:
        return {"op": "click", "slot": slot, "button": rnd.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 40]), "input": 2}
    if r < 0.74:
        return {"op": "click", "slot": slot, "button": rnd.randint(0, 1), "input": 4, "clean": True}
    if r < 0.80:
        return {"op": "click", "slot": rnd.choice([-999, slot]), "button": rnd.randint(0, 1), "input": 0, "clean": True}
    if r < 0.88:
        return {"op": "click", "slot": slot, "button": rnd.randint(0, 1), "input": 6}
    # a drag: start, add some slots, end (button = header | type << 2: header 0 start, 1 add, 2 end; type 0 left, 1 right)
    typ = rnd.randint(0, 1)
    cand = [s for s in range(0, n_slots) if s not in (0,)] if True else []
    pick = rnd.sample(cand, rnd.randint(1, min(5, len(cand))))
    return {"op": "drag", "type": typ, "slots": pick}


def run_action(p, act):
    c = p.c
    if act["op"] == "click":
        p.send_click(act["slot"], act["button"], act["input"], changed=act.get("changed"), carried=act.get("carried"))
    elif act["op"] == "drag":
        t = act["type"]
        car = p.carried if "changed" in act else None             # claims mode: the cursor does not change until the drag ends
        p.send_click(-999, 0 | (t << 2), 5, carried=car); time.sleep(0.07)
        for s in act["slots"]:
            p.send_click(s, 1 | (t << 2), 5, carried=car); time.sleep(0.07)
        p.send_click(-999, 2 | (t << 2), 5, changed=act.get("changed"), carried=act.get("carried"))
    elif act["op"] == "close":
        c.send("minecraft:container_close", m.varint(p.cid))
        p.to_inventory()
    elif act["op"] == "cmd":
        p.cmd(act["text"])
    elif act["op"] == "sql":
        if p.a.mode == "dbcraft":
            p.sql(act["text"])
    elif act["op"] == "use":
        x, y, z = act["pos"]
        c.send("minecraft:use_item_on", m.varint(0) + m.position(x, y, z) + m.varint(act.get("face", 1)) + struct.pack(">fff", 0.5, 1.0, 0.5) + b"\x00\x00" + m.varint(1))
    elif act["op"] == "input":
        c.send("minecraft:player_input", bytes([act["flags"]]))
    elif act["op"] == "held":
        c.send("minecraft:set_carried_item", struct.pack(">h", act["slot"]))


BLOCK = (2, -60, 0)
BLOCKLESS = ("inv", "craft")             # scenarios in the player's own inventory menu
BLOCK2 = (3, -60, 0)
FACINGS = ["north", "east", "south", "west"]
PARTNER = {"north": (1, 0, 0), "east": (0, 0, 1), "south": (-1, 0, 0), "west": (0, 0, -1)}   # where the LEFT half's partner (clockwise of its facing) stands
FURNACE_IN = ["minecraft:raw_iron", "minecraft:raw_copper", "minecraft:potato", "minecraft:sand", "minecraft:cobblestone", "minecraft:oak_log", "minecraft:beef", "minecraft:iron_ore"]
FUELS = ["minecraft:coal", "minecraft:oak_planks", "minecraft:stick", "minecraft:lava_bucket", "minecraft:bucket", "minecraft:blaze_rod", "minecraft:oak_log"]


def gen_block(rnd, scen):
    """what the block's container holds (slot -> (item, count)), by scenario"""
    slots = {}
    if scen in ("chest", "barrel", "ender"):
        for s in range(27):
            if rnd.random() < 0.5:
                it = rnd.choice(list(PALETTE)); slots[s] = (it, rnd.randint(1, PALETTE[it]) if rnd.random() < 0.6 else 1)
    elif scen == "double":
        for s in range(54):
            if rnd.random() < 0.4:
                it = rnd.choice(list(PALETTE)); slots[s] = (it, rnd.randint(1, PALETTE[it]) if rnd.random() < 0.6 else 1)
    elif scen in ("furnace", "blast", "smoker"):
        if rnd.random() < 0.9:
            it = rnd.choice(FURNACE_IN); slots[0] = (it, rnd.randint(1, 6))
        if rnd.random() < 0.8:
            it = rnd.choice(FUELS); slots[1] = (it, 1 if it in ("minecraft:lava_bucket", "minecraft:bucket") else rnd.randint(1, 5))
    return slots


BLOCK_NAME = {"chest": "minecraft:chest", "barrel": "minecraft:barrel", "ender": "minecraft:ender_chest", "table": "minecraft:crafting_table", "furnace": "minecraft:furnace",
              "blast": "minecraft:blast_furnace", "smoker": "minecraft:smoker"}


def setup_world(p, scen, block, facing="north"):
    """place the block (and fill it) on the server being probed; the same thing through RCON for vanilla and through SQL for dbcraft"""
    x, y, z = BLOCK
    block2 = (x + PARTNER[facing][0], y, z + PARTNER[facing][2])
    p.say("tp %s 0.5 -60 0.5" % p.a.name); time.sleep(0.5)
    if scen in BLOCKLESS:
        return
    names = [(f"minecraft:chest[facing={facing},type=left]", BLOCK), (f"minecraft:chest[facing={facing},type=right]", block2)] if scen == "double" else [(BLOCK_NAME[scen], BLOCK)]
    if p.a.mode == "vanilla":
        p.rc.cmd("kill @e[type=item]")
        for off in [(0, 0, 0)] + list(PARTNER.values()):
            p.rc.cmd(f"setblock {x + off[0]} {y} {z + off[2]} minecraft:air")
        for nm, (bx, by, bz) in names:
            p.rc.cmd(f"setblock {bx} {by} {bz} {nm}")
        if scen == "ender":
            for sl in range(27):
                p.rc.cmd(f"item replace entity {p.a.name} enderchest.{sl} with minecraft:air")
            for sl, (it, n) in block.items():
                p.rc.cmd(f"item replace entity {p.a.name} enderchest.{sl} with {it} {n}")
        else:
            for sl, (it, n) in block.items():
                bx, bz = x, z
                if scen == "double":      # the same halves as below: the RIGHT half (the partner) is slots 0-26, the LEFT half (BLOCK) slots 27-53
                    bx, bz = (block2[0], block2[2]) if sl < 27 else (x, z)
                    sl = sl % 27
                p.rc.cmd(f"item replace block {bx} {y} {bz} container.{sl} with {it} {n}")
    else:
        for off in [(0, 0, 0)] + list(PARTNER.values()):
            p.sql("select mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:air')" % (x + off[0], y, z + off[2]))
        p.sql("delete from mc.container_slot; delete from mc.furnace")
        for nm, (bx, by, bz) in names:
            p.sql("select mc.set_block('minecraft:overworld', %d, %d, %d, '%s')" % (bx, by, bz, nm.replace(f"[facing={facing},type=left]", f"[type=left,facing={facing},waterlogged=false]").replace(f"[facing={facing},type=right]", f"[type=right,facing={facing},waterlogged=false]")))
        if scen == "ender":
            p.sql("delete from mc.ender_slot where player in (select uuid from mc.player where name = '%s')" % p.a.name)
            for sl, (it, n) in block.items():
                p.sql("insert into mc.ender_slot select uuid, %d, '%s', %d, null from mc.player where name = '%s'" % (sl, it, n, p.a.name))
        else:
            for sl, (it, n) in block.items():
                if scen == "double":      # DoubleBlockCombiner: the RIGHT half (the partner) holds slots 0-26, the LEFT half (2, -60, 0) slots 27-53
                    bx, by, bz = block2 if sl < 27 else BLOCK
                    sl = sl % 27
                else:
                    bx, by, bz = BLOCK
                p.sql("insert into mc.container_slot values ('minecraft:overworld', %d, %d, %d, %d, '%s', %d, null)" % (bx, by, bz, sl, it, n))
    time.sleep(0.6)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["vanilla", "dbcraft"], required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--rcon", type=int); ap.add_argument("--rcon-pw", default="dbcraft-cont")
    ap.add_argument("--psql")
    ap.add_argument("--name", default="Cont")
    ap.add_argument("--scenario", default="inv")
    ap.add_argument("--seed", type=int, default=1); ap.add_argument("--steps", type=int, default=30)
    ap.add_argument("--actions"); ap.add_argument("--out", required=True)
    ap.add_argument("--claims", action="store_true", help="claim the first run's effect in changedSlots / carried (what a real client sends)")
    ap.add_argument("--dump", action="store_true", default=True)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    p = Probe(a)
    plan = json.load(open(a.actions)) if a.actions else None
    if a.mode == "vanilla":
        p.rc.cmd("gamerule send_command_feedback false")
        p.rc.cmd("op " + a.name)
    else:
        p.sql("insert into mc.op (uuid, name, level) select uuid, name, 4 from mc.player where name = '%s' on conflict do nothing" % a.name)
    if a.mode == "dbcraft":                           # a clean slate: the join then carries an empty inventory at state id 1, like vanilla's saved-then-cleared one
        p.sql("delete from mc.inventory_slot where player in (select uuid from mc.player where name = '%s')" % a.name)
        p.sql("delete from mc.menu_state where player in (select uuid from mc.player where name = '%s')" % a.name)
    p.connect()
    if a.mode == "dbcraft":
        p.sql("insert into mc.op (uuid, name, level) select uuid, name, 4 from mc.player where name = '%s' on conflict do nothing" % a.name)
    stacks = {int(k): tuple(v) for k, v in plan["stacks"].items()} if plan else gen_stacks(rnd, a.scenario)
    scen = plan["scenario"] if plan else a.scenario
    block = {int(k): tuple(v) for k, v in plan["block"].items()} if plan else gen_block(rnd, a.scenario)
    facing = plan.get("facing") if plan else FACINGS[a.seed % 4]
    p.reset_player(stacks)
    setup_world(p, scen, block, facing)
    result = {"scenario": scen, "facing": facing, "block": {str(k): list(v) for k, v in block.items()}, "seed": plan.get("seed", a.seed) if plan else a.seed, "stacks": {str(k): list(v) for k, v in stacks.items()}, "steps": [], "initial": {"menu": {str(k): v for k, v in p.menu.items()}}}
    actions = plan["steps"] if plan else None
    n = len(actions) if actions else a.steps
    p.c.mark("start")
    for i in range(n):
        act = None
        if not plan and scen not in BLOCKLESS and i == 0:
            act = {"op": "use", "pos": list(BLOCK)}
        elif not plan and i == n - 1:
            act = {"op": "close"}
        if plan:
            act = dict(actions[i]["action"])
        elif act is None:
            act = gen_action(rnd, p, scen)
        k = p.c.count()
        if plan and a.claims and actions[i].get("effect"):
            act["changed"] = {int(s): (v and tuple(v)) for s, v in actions[i]["effect"]["changed"].items()}
            act["carried"] = actions[i]["effect"]["carried"] and tuple(actions[i]["effect"]["carried"])
        run_action(p, act)
        p.settle(0.2)
        if act.get("clean") and a.mode == "vanilla":
            p.rc.cmd("kill @e[type=item]")
        if act["op"] == "use":                            # wait for the menu to open (a loaded machine answers late): the stale click below must name the new container
            for _ in range(60):
                if p.c.since(k, {"minecraft:open_screen"}) and p.c.since(k, {"minecraft:container_set_content"}):
                    break
                time.sleep(0.1)
            p.settle(0.2)
        p.sync_from(k)
        # the full state: a click with a state id that cannot be the server's makes it send the whole menu
        k2 = p.c.count()
        p.send_click(-1, 0, 0, state=(p.state + 20000) & 32767)
        dump_j = None
        for _ in range(80):                               # up to 8 s for the answer, then a quiet moment
            time.sleep(0.1)
            sc = [j for j, e in enumerate(list(p.c.events[k:])) if j >= k2 - k and e["dir"] == "clientbound" and e["name"] == "minecraft:container_set_content" and e["body"][0] == p.cid]      # (the answer to the stale click, not the open's own)
            if sc:
                dump_j = sc[-1]
                break
        p.settle(0.2)
        red = []
        for j, e in enumerate(list(p.c.events[k:])):
            if e["dir"] == "clientbound" and e["name"].replace("minecraft:", "") in KINDS:
                try:
                    r = reduce_packet(e)
                except ValueError:
                    r = None
                if r:
                    red.append((j, r))
        pk = [r for j, r in red if dump_j is None or j < dump_j]
        full = [r for j, r in red if dump_j is not None and j >= dump_j]
        p.sync_from(k)
        # what the click changed, from the packets: used to build claims for the second kind of run
        changed = {}
        for r in pk:
            if r[0] == "set_slot" and r[3] != 0 and r[1] == p.cid:
                changed[str(r[3])] = r[4]
        if act.get("op") == "click" and act["slot"] == 0 and act["input"] in (0, 1, 2, 4):
            changed["0"] = None                       # the client takes the result out of its copy of the slot
        effect = {"changed": changed, "carried": p.carried}
        result["steps"].append({"action": act, "packets": pk, "state": full, "effect": effect})
        print(f"step {i}: {json.dumps(act)} -> " + ", ".join(r[0] for r in pk))
    json.dump(result, open(a.out, "w"), indent=0)
    p.c.close()


main()
