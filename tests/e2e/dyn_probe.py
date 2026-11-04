#!/usr/bin/env python3
"""World dynamics (fluids, falling blocks, ...) as a client sees them, tick by tick: the same scenario runs on the REAL vanilla 26.3 server (RCON, the tick frozen with
`/tick freeze` and advanced with `/tick step 1`, a scripted client records every block-change packet after each step) and on dbcraft (SQL: the game clock moved by hand,
mc.dyn_step, mc.broadcast_block_events, the packets of a fake connection read back from mc.play_out).  `compare` then requires the packets of every step to be equal.

usage:
  dyn_probe.py vanilla  --port 25641 --rcon 25645 [--rcon-pw dynpw] --out vanilla.json [--only NAME,NAME]
  dyn_probe.py dbcraft  --psql 'psql -X -At -h /tmp -p 55731 -U postgres dbcraft' --out ours.json [--only NAME,NAME]
  dyn_probe.py compare  vanilla.json ours.json

A scenario is a list of ops: ("fill", x1, y1, z1, x2, y2, z2, block), ("set", x, y, z, block), ("step", n), ("rec",) (start recording; what came before is set-up).
Everything happens in the flat world's air above the grass layer (y = -61 is the top block of the flat world).
"""
import argparse, json, os, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

AIR_BOX = (-20, -60, -20, 20, -40, 20)          # cleaned before every scenario

SCEN = {
    # one source on open ground: the diamond of 7 levels
    "water_flat": [("fill", *AIR_BOX, "air"), ("step", 3), ("rec",), ("set", 0, -60, 0, "water"), ("step", 60)],
    # a source on a ledge above the floor: falls, spreads, slope search toward a hole
    "water_ledge": [("fill", *AIR_BOX, "air"), ("fill", -6, -60, -6, 6, -60, 6, "stone"), ("fill", -3, -60, -1, -3, -60, 1, "air"), ("step", 3), ("rec",),
                    ("set", 0, -59, 0, "water"), ("step", 60)],
    # a source next to a pit: the flow takes the shortest way down (getSpread / getSlopeDistance)
    "water_hole": [("fill", *AIR_BOX, "air"), ("fill", -8, -61, -8, 8, -61, 8, "stone"), ("fill", 3, -61, 0, 3, -61, 0, "air"), ("fill", -2, -61, 3, -2, -61, 3, "air"),
                   ("step", 3), ("rec",), ("set", 0, -60, 0, "water"), ("step", 60)],
    # two sources and a gap: the gap becomes a source (water_source_conversion)
    "water_infinite": [("fill", *AIR_BOX, "air"), ("fill", -3, -61, -3, 3, -61, 3, "stone"), ("fill", -1, -60, -1, 1, -60, 1, "stone"), ("fill", 0, -60, 0, 0, -60, 0, "air"),
                       ("step", 3), ("rec",), ("set", -1, -59, 0, "water"), ("set", 1, -59, 0, "water"), ("step", 40)],
    # walls of every shape: full blocks, slabs, stairs, a fence, a trapdoor
    "water_shapes": [("fill", *AIR_BOX, "air"), ("fill", -9, -61, -9, 9, -61, 9, "stone"), ("set", 2, -60, 0, "stone"), ("set", 3, -60, 1, "oak_slab"), ("set", 4, -60, -1, "oak_stairs"),
                     ("set", 2, -60, 3, "oak_fence"), ("set", 0, -60, 3, "oak_trapdoor"), ("set", -2, -60, 0, "stone_slab[type=top,waterlogged=false]"), ("set", -2, -60, 1, "stone_slab[type=bottom,waterlogged=false]"),
                     ("step", 3), ("rec",), ("set", 0, -60, 0, "water"), ("step", 60)],
    # lava on flat ground (30 ticks per step, slope distance 2)
    "lava_flat": [("fill", *AIR_BOX, "air"), ("step", 3), ("rec",), ("set", 0, -60, 0, "lava"), ("step", 130)],
    # lava meets water: cobblestone from flowing lava, obsidian from a lava source, stone from lava falling on water
    "lava_water": [("fill", *AIR_BOX, "air"), ("fill", -8, -61, -8, 8, -61, 8, "stone"), ("step", 3), ("rec",), ("set", 0, -60, 0, "lava"), ("set", 6, -60, 0, "water"), ("step", 100)],
    "lava_falls_on_water": [("fill", *AIR_BOX, "air"), ("fill", -8, -61, -8, 8, -61, 8, "stone"), ("set", 0, -60, 0, "water"), ("step", 20), ("rec",), ("set", 0, -58, 0, "lava"), ("step", 80)],
    # sand, gravel and concrete powder: fall when unsupported, land after the fall time; powder turns to concrete in water
    "sand_fall": [("fill", *AIR_BOX, "air"), ("fill", -3, -61, -3, 3, -61, 3, "stone"), ("step", 3), ("rec",), ("set", 0, -50, 0, "sand"), ("set", 1, -50, 0, "gravel"),
                  ("set", 2, -55, 0, "red_sand"), ("set", 2, -54, 0, "sand"), ("set", 2, -53, 0, "sand"), ("step", 80)],
    "powder_water": [("fill", *AIR_BOX, "air"), ("fill", -3, -61, -3, 3, -61, 3, "stone"), ("set", 1, -60, 0, "water"), ("step", 12), ("rec",), ("set", 0, -55, 0, "red_concrete_powder"),
                     ("set", 1, -55, 0, "white_concrete_powder"), ("step", 80)],
    # blocks that need support break when it goes (torches, plants, doors, carpets, ladders, buttons, signs): the neighbour updates of Level.setBlock
    "support_breaks": [("fill", *AIR_BOX, "air"), ("fill", -9, -61, -9, 9, -61, 9, "stone"),
                       ("set", 0, -60, 0, "stone"), ("set", 0, -59, 0, "torch"),
                       ("set", 2, -61, 0, "grass_block[snowy=false]"), ("set", 2, -60, 0, "poppy"),
                       ("set", 4, -61, 0, "grass_block[snowy=false]"), ("set", 4, -60, 0, "tall_grass[half=lower]"), ("set", 4, -59, 0, "tall_grass[half=upper]"),
                       ("set", 6, -60, 0, "oak_door[facing=north,half=lower,hinge=left,open=false,powered=false]"), ("set", 6, -59, 0, "oak_door[facing=north,half=upper,hinge=left,open=false,powered=false]"),
                       ("set", 8, -60, 0, "white_carpet"), ("set", -2, -60, 0, "stone"), ("set", -2, -60, 1, "wall_torch[facing=south]"),
                       ("set", -4, -60, 0, "stone"), ("set", -4, -60, 1, "ladder[facing=south,waterlogged=false]"), ("set", -6, -60, 0, "stone"), ("set", -6, -60, 1, "stone_button[face=wall,facing=south,powered=false]"),
                       ("set", 0, -60, 4, "farmland[moisture=0]"), ("set", 0, -59, 4, "wheat[age=0]"), ("set", 2, -60, 4, "stone"), ("set", 2, -59, 4, "oak_sign[rotation=0,waterlogged=false]"),
                       ("step", 3), ("rec",),
                       ("set", 0, -60, 0, "air"), ("step", 2), ("set", 2, -61, 0, "air"), ("step", 2), ("set", 4, -61, 0, "air"), ("step", 2), ("set", 6, -61, 0, "air"), ("step", 2),
                       ("set", 8, -61, 0, "air"), ("step", 2), ("set", -2, -60, 0, "air"), ("step", 2), ("set", -4, -60, 0, "air"), ("step", 2), ("set", -6, -60, 0, "air"), ("step", 2),
                       ("set", 0, -60, 4, "air"), ("step", 2), ("set", 2, -60, 4, "air"), ("step", 3),
                       ("set", 4, -59, 0, "air"), ("step", 3)],
    "sand_support_removed": [("fill", *AIR_BOX, "air"), ("fill", -3, -61, -3, 3, -61, 3, "stone"), ("fill", 0, -60, 0, 0, -56, 0, "sand"), ("set", 0, -60, 1, "stone"), ("step", 5), ("rec",),
                             ("set", 0, -60, 0, "air"), ("step", 60)],
}


def decode_changes(packets, state_name):
    """[(name, x, y, z, state or None)] in packet order: block_update / section_blocks_update entries, level_event as ('event', type)."""
    out = []
    for p in packets:
        b = bytes.fromhex(p["hex"])
        if p["name"] == "minecraft:block_update":
            v = struct.unpack(">Q", b[:8])[0]
            x = v >> 38; z = (v >> 12) & 0x3FFFFFF; y = v & 0xFFF
            x -= (1 << 26) if x >= (1 << 25) else 0; z -= (1 << 26) if z >= (1 << 25) else 0; y -= (1 << 12) if y >= (1 << 11) else 0
            sid = 0; sh = 0; o = 8
            while True:
                c = b[o]; o += 1; sid |= (c & 127) << sh; sh += 7
                if not c & 128: break
            out.append(("b", x, y, z, state_name.get(sid, str(sid))))
        elif p["name"] == "minecraft:section_blocks_update":
            v = struct.unpack(">Q", b[:8])[0]
            sx = v >> 42; sy = v & 0xFFFFF; sz = (v >> 20) & 0x3FFFFF
            sx -= (1 << 22) if sx >= (1 << 21) else 0; sy -= (1 << 20) if sy >= (1 << 19) else 0; sz -= (1 << 22) if sz >= (1 << 21) else 0
            o = 8; n = 0; sh = 0
            while True:
                c = b[o]; o += 1; n |= (c & 127) << sh; sh += 7
                if not c & 128: break
            for _ in range(n):
                val = 0; sh = 0
                while True:
                    c = b[o]; o += 1; val |= (c & 127) << sh; sh += 7
                    if not c & 128: break
                idx = val & 4095; sid = val >> 12
                out.append(("s", sx * 16 + (idx >> 8), sy * 16 + (idx & 15), sz * 16 + ((idx >> 4) & 15), state_name.get(sid, str(sid))))
        elif p["name"] == "minecraft:level_event":
            out.append(("e", struct.unpack(">i", b[:4])[0], 0, 0, "event"))
    return out


KEEP = ("minecraft:block_update", "minecraft:section_blocks_update", "minecraft:level_event")


def gametime(rc):
    import re
    return int(re.search(r"(\d+)", rc.cmd("time query gametime")).group(1))


def run_vanilla(a):
    import mcclient as m
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
    import common as C
    rc = C.Rcon(port=a.rcon, pw=a.rcon_pw)
    rc.cmd("gamerule random_tick_speed 0")
    rc.cmd("gamerule max_block_modifications 2000000")
    rc.cmd("gamerule spawn_mobs false")
    c = m.Client("127.0.0.1", a.port, "Dyn")
    c.settle(1.0, 15.0)
    rc.cmd("tp Dyn 0 -30 30"); c.settle(0.5, 5.0)
    rc.cmd("tick freeze")
    res = {}
    for name, ops in SCEN.items():
        if a.only and name not in a.only.split(","):
            continue
        recording = False; steps = []; k_prev = c.count()
        for op in ops:
            if op[0] == "rec":
                recording = True; k_prev = c.count(); continue
            if op[0] == "fill":
                rc.cmd("fill %d %d %d %d %d %d minecraft:%s" % (*op[1:7], op[7]))
            elif op[0] == "set":
                rc.cmd("setblock %d %d %d minecraft:%s" % (op[1], op[2], op[3], op[4]))
            elif op[0] == "step":
                for _ in range(op[1]):
                    g = gametime(rc)
                    rc.cmd("tick step 1")                                  # asynchronous: the answer comes before the tick has run, so wait for the clock
                    for _w in range(200):
                        if gametime(rc) > g:
                            break
                        time.sleep(0.01)
                    time.sleep(0.12)
                    if recording:
                        # (from the end of the previous step: what a command sent at once, a break effect for one, belongs to the step it was given before)
                        steps.append([{"name": e["name"], "hex": e["body"].hex()} for e in c.since(k_prev) if e["name"] in KEEP])
                    k_prev = c.count()
        res[name] = steps
        print(name, "steps", len(steps), "packets", sum(len(s) for s in steps))
    c.close()
    json.dump(res, open(a.out, "w"))


def run_dbcraft(a):
    psql = a.psql.split()

    def sql(q):
        r = subprocess.run(psql + ["-c", q], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stderr)
        return r.stdout

    sql("truncate net.conn, mc.play_out, mc.block_event, mc.block_tick; delete from mc.player; "
        "insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 0, 0); "
        "insert into mc.player (uuid, name, conn_id, entity_id, chunk_x, chunk_z) values ('00000000-0000-0000-0000-00000000d001', 'Dyn', 1, 1, 0, 0); "
        "insert into mc.game_rule (name, value) values ('minecraft:random_tick_speed', '0') on conflict (name) do update set value = '0'")
    sql("select mc.generate_flat_area('minecraft:overworld', -3, -3, 3, 3)")
    res = {}
    for name, ops in SCEN.items():
        if a.only and name not in a.only.split(","):
            continue
        recording = False; steps = []
        for op in ops:
            if op[0] == "rec":
                recording = True; continue
            if op[0] == "fill":
                sql("select mc.fill('minecraft:overworld', %d, %d, %d, %d, %d, %d, 'minecraft:%s')" % (*op[1:7], op[7]))
            elif op[0] == "set":
                # like /setblock: the block is announced and no break effect is sent (mc.set_block would add a level_event 2001 for a removal): the event is turned into a one-cell fill event
                sql("do $$ declare m bigint; begin select coalesce(max(id), 0) into m from mc.block_event; perform mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:%s'); "
                    "update mc.block_event e set kind = 'cells', x = (e.x >> 4) * 16, y = (e.y >> 4) * 16, z = (e.z >> 4) * 16, cells = mc.box_bitmap(e.x & 15, e.x & 15, e.y & 15, e.y & 15, e.z & 15, e.z & 15) where e.id = (select min(id) from mc.block_event where id > m); end $$" % (op[1], op[2], op[3], op[4]))
            elif op[0] == "step":
                for _ in range(op[1]):
                    out = sql("do $$ declare cur bigint; begin update mc.game_state set game_time = game_time + 1 returning game_time into cur; perform mc.dyn_step(cur); "
                              "perform mc.broadcast_block_events(); "
                              "perform mc.dyn_release_late(); perform mc.broadcast_block_events(); end $$; select encode(data, 'hex') from mc.play_out where conn_id = 1 order by seq; delete from mc.play_out;")
                    if recording:
                        steps.append([f for h in out.split() if len(h) > 5 and all(ch in "0123456789abcdef" for ch in h) for f in frames(h)])
        res[name] = steps
        print(name, "steps", len(steps), "packets", sum(len(s) for s in steps))
    json.dump(res, open(a.out, "w"))


def _varint(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 127) << s; s += 7
        if not c & 128:
            return v, o


_ID = None


def pname(h):
    global _ID
    if _ID is None:
        import mcclient as m
        _ID = {m.ID[("play", "clientbound", n)]: "minecraft:" + n.replace("minecraft:", "") for (st, d, n) in m.ID if st == "play" and d == "clientbound"}
    b = bytes.fromhex(h)
    ln, o = _varint(b, 0)
    pid, o = _varint(b, o)
    return _ID.get(pid, "#%d" % pid)


def frames(h):
    """the packets of one play_out row (a row may hold several frames)"""
    b = bytes.fromhex(h); o = 0; out = []
    while o < len(b):
        ln, o2 = _varint(b, o)
        out.append({"name": pname(b[o:o2 + ln].hex()), "hex": body(b[o:o2 + ln].hex())})
        o = o2 + ln
    return out


def body(h):
    b = bytes.fromhex(h)
    ln, o = _varint(b, 0)
    pid, o = _varint(b, o)
    return b[o:].hex()


def compare(a):
    import mcclient as m
    van = json.load(open(a.files[0])); ours = json.load(open(a.files[1]))
    bad = 0
    for name in van:
        if name not in ours:
            continue
        vs, os_ = van[name], ours[name]
        diffs = []
        for i, (x, y) in enumerate(zip(vs, os_)):
            xs = [p for p in x if p["name"] in KEEP]; ys = [p for p in y if p["name"] in KEEP]
            # vanilla sends the packets of different chunks in the order of a hash set (it changes between runs): a step is compared as a multiset of packets; the entries inside a
            # section_blocks_update are in set order and compared byte for byte
            if sorted((p["name"], p["hex"]) for p in xs) != sorted((p["name"], p["hex"]) for p in ys):
                diffs.append(i)
        nv = sum(len(s) for s in vs)
        print(f"{name}: {len(vs)} steps, vanilla {nv} packets, dbcraft {sum(len(s) for s in os_)}; steps that differ: {len(diffs)} {diffs[:12]}")
        if diffs and a.verbose:
            for i in diffs[:a.verbose]:
                cv = decode_changes(vs[i], m.STATE_NAME); co = decode_changes(os_[i], m.STATE_NAME)
                print(f"  step {i}: vanilla {cv[:14]}")
                print(f"          dbcraft {co[:14]}")
        bad += 1 if diffs or len(vs) != len(os_) else 0
    print("ALL IDENTICAL" if not bad else f"{bad} scenario(s) differ")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["vanilla", "dbcraft", "compare"])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--port", type=int, default=25641); ap.add_argument("--rcon", type=int, default=25645); ap.add_argument("--rcon-pw", default="dynpw")
    ap.add_argument("--psql"); ap.add_argument("--out"); ap.add_argument("--only"); ap.add_argument("--verbose", type=int, default=0)
    a = ap.parse_args()
    if a.mode == "vanilla":
        run_vanilla(a)
    elif a.mode == "dbcraft":
        run_dbcraft(a)
    else:
        sys.exit(compare(a))


main()
