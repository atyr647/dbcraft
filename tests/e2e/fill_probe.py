#!/usr/bin/env python3
"""Multi-block changes as one client sees them: a scripted client joins, a server-side command changes blocks, every packet the client receives is recorded.
Run it against the REAL vanilla 26.3 server (commands over RCON) and against dbcraft (SQL through psql) with the same steps, then compare with
tests/e2e/compare_fill.py.  Tests the vanilla rule that docs/WORLD.md "Block change packets" describes: per section and tick, a set of changed positions;
one position -> block_update, two or more -> section_blocks_update (VarInt count, then VarLong state << 12 | (x << 8 | z << 4 | y), in fastutil
ShortOpenHashSet iteration order).

usage:
  vanilla:  fill_probe.py --mode vanilla --port 25661 --rcon 25675 --rcon-pw pw [--world DIR] --out /tmp/x/vanilla_fill.json
  dbcraft:  fill_probe.py --mode dbcraft --port 25681 --psql 'psql -X -At -h /tmp -p 54881 -U postgres dbcraft' --out /tmp/x/ours_fill.json
--world DIR (vanilla): the server's world directory; a datapack with one function per batch step is written there and /reload-ed (a batch of /setblock
commands in one function runs in one tick, which is what mc.set_blocks models).
"""
import argparse, json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

DIM = "minecraft:overworld"
KEEP = ("minecraft:block_update", "minecraft:section_blocks_update", "minecraft:level_event", "minecraft:light_update", "minecraft:block_entity_data",
        "minecraft:level_chunk_with_light", "minecraft:forget_level_chunk", "minecraft:block_changed_ack", "minecraft:block_destruction", "minecraft:sound")

BLOCKS = ["stone", "gold_block", "iron_block", "diamond_block", "emerald_block", "lapis_block", "redstone_block", "coal_block", "copper_block", "netherite_block",
          "oak_planks", "spruce_planks", "birch_planks", "jungle_planks", "acacia_planks", "dark_oak_planks", "cobblestone", "mossy_cobblestone", "bricks", "sandstone",
          "red_sandstone", "glass", "white_wool", "orange_wool", "magenta_wool"]


def steps():
    """(label, kind, args).  kind 'set': one /setblock; 'fill': one /fill (x1 y1 z1 x2 y2 z2 block); 'batch': several /setblock in one tick (list of (x, y, z, block))."""
    s = [("single block", "set", (5, -60, 5, "stone")),
         ("two blocks in one section", "fill", (5, -60, 6, 6, -60, 6, "gold_block")),
         ("single block fill", "fill", (7, -45, 7, 7, -45, 7, "glass"))]
    shapes = [(4, 3, 2), (5, 1, 5), (4, 3, 4), (7, 1, 7), (4, 6, 4), (7, 2, 7), (4, 12, 4), (14, 1, 14), (8, 6, 8), (7, 8, 7), (16, 3, 16), (16, 7, 7),
              (16, 6, 16), (16, 7, 14), (16, 12, 16), (16, 14, 14), (16, 16, 16)]
    for i, (xs, ys, zs) in enumerate(shapes):                       # N = 24, 25, 48, 49, 96, 98, 192, 196, 384, 392, 768, 784, 1536, 1568, 3072, 3136, 4096
        b = BLOCKS[(i + 1) % len(BLOCKS)]
        s.append((f"{xs}x{ys}x{zs} in section -3 ({xs * ys * zs} blocks)", "fill", (0, -48, 0, xs - 1, -48 + ys - 1, zs - 1, b)))
    s += [("again the same fill: nothing changes", "fill", (0, -48, 0, 15, -33, 15, BLOCKS[len(shapes) % len(BLOCKS)])),
          ("overlap: only the new positions change", "fill", (-8, -50, -8, 24, -30, 24, "stone")),
          ("same fill again", "fill", (-8, -50, -8, 24, -30, 24, "stone")),
          ("partly stone already, now stone again over more", "fill", (-12, -52, -12, 28, -26, 28, "stone")),
          ("to air", "fill", (-8, -50, -8, 24, -30, 24, "air")),
          ("grass layer to dirt (a palette section)", "fill", (0, -61, 0, 15, -61, 15, "dirt")),
          ("9 chunks, 49x11x49", "fill", (-20, -60, -20, 28, -50, 28, "stone")),
          ("the same area to air", "fill", (-20, -60, -20, 28, -50, 28, "air"))]
    # a batch in one tick: scattered positions in two sections, a position set twice, a position set and set back
    import random
    rnd = random.Random(7)
    batch = [(rnd.randrange(0, 16), -60 + rnd.randrange(0, 3), rnd.randrange(0, 16), BLOCKS[rnd.randrange(0, 6)]) for _ in range(30)]
    batch += [(rnd.randrange(0, 16), -40 + rnd.randrange(0, 4), rnd.randrange(0, 16), BLOCKS[rnd.randrange(0, 6)]) for _ in range(40)]
    batch += [(3, -60, 3, "gold_block"), (3, -60, 3, "iron_block"), (9, -60, 9, "gold_block"), (9, -60, 9, "air")]
    s.append(("batch of 74 /setblock in one tick", "batch", batch))
    batch2 = [(40 + i, -60, 40, "stone") for i in range(5)]
    s.append(("batch of 5 in another chunk", "batch", batch2))
    s.append(("a batch that changes one block twice (one position)", "batch", [(41, -58, 41, "stone"), (41, -58, 41, "gold_block")]))
    s.append(("a batch that changes a block and back (one position)", "batch", [(42, -58, 42, "stone"), (42, -58, 42, "air")]))
    return s


def sql_for(kind, args):
    if kind == "set":
        x, y, z, b = args
        return f"select mc.set_block('{DIM}', {x}, {y}, {z}, 'minecraft:{b}')"
    if kind == "fill":
        x1, y1, z1, x2, y2, z2, b = args
        return f"select mc.fill('{DIM}', {x1}, {y1}, {z1}, {x2}, {y2}, {z2}, 'minecraft:{b}')"
    xs = ",".join(str(a[0]) for a in args); ys = ",".join(str(a[1]) for a in args); zs = ",".join(str(a[2]) for a in args)
    bs = ",".join("'minecraft:%s'" % a[3] for a in args)
    return f"select mc.set_blocks('{DIM}', array[{xs}], array[{ys}], array[{zs}], array[{bs}]::text[])"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["vanilla", "dbcraft"], required=True)
    ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--rcon", type=int); ap.add_argument("--rcon-pw", default="pw"); ap.add_argument("--world")
    ap.add_argument("--psql", help="psql command line for the dbcraft database")
    ap.add_argument("--out", required=True); ap.add_argument("--name", default="Filler"); ap.add_argument("--settle", type=float, default=1.2)
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
    st = steps()
    rc = None
    if a.mode == "vanilla":
        import common as C
        rc = C.Rcon(port=a.rcon, pw=a.rcon_pw)
        if a.world:
            pack = os.path.join(a.world, "datapacks", "probe")
            fdir = os.path.join(pack, "data", "probe", "function")
            os.makedirs(fdir, exist_ok=True)
            json.dump({"pack": {"description": "probe", "min_format": 121, "max_format": 121}}, open(os.path.join(pack, "pack.mcmeta"), "w"))
            for i, (label, kind, args) in enumerate(st):
                if kind == "batch":
                    with open(os.path.join(fdir, f"b{i}.mcfunction"), "w") as f:
                        for (x, y, z, b) in args:
                            f.write(f"setblock {x} {y} {z} minecraft:{b}\n")
            print(rc.cmd("reload"))
            time.sleep(2)
            print(rc.cmd("datapack list"))
    c = m.Client(a.host, a.port, a.name)
    c.settle(1.0, 15.0)
    print("client at", c.pos)
    if a.mode == "vanilla":
        print(rc.cmd("gamerule max_block_modifications 2000000"))
        print(rc.cmd("gamerule random_tick_speed 0"))          # no random ticks: grass would otherwise decay to dirt under the stone and add unrelated block changes
    out = []
    for i, (label, kind, args) in enumerate(st):
        k = c.count(); c.mark(label)
        t0 = time.time()
        resp = ""
        if a.mode == "vanilla":
            if kind == "set":
                x, y, z, b = args; resp = rc.cmd(f"setblock {x} {y} {z} minecraft:{b}")
            elif kind == "fill":
                x1, y1, z1, x2, y2, z2, b = args; resp = rc.cmd(f"fill {x1} {y1} {z1} {x2} {y2} {z2} minecraft:{b}")
            else:
                resp = rc.cmd(f"function probe:b{i}")
        else:
            r = subprocess.run(a.psql.split() + ["-c", sql_for(kind, args)], capture_output=True, text=True)
            resp = (r.stdout + r.stderr).strip()
        time.sleep(a.settle)        # a fixed wait: the server keeps sending time and keep-alive packets, so "quiet" never comes
        got = [e for e in c.since(k) if e["name"] in KEEP]
        out.append({"label": label, "kind": kind, "response": resp, "packets": [{"name": e["name"], "hex": e["body"].hex()} for e in got]})
        print(f"[{label}] {resp[:60]!r} -> " + ", ".join(f"{e['name'].replace('minecraft:', '')}({len(e['body'])}B)" for e in got if e["name"] != "minecraft:light_update") +
              (f" +{sum(1 for e in got if e['name'] == 'minecraft:light_update')} light_update" if any(e["name"] == "minecraft:light_update" for e in got) else ""))
    json.dump(out, open(a.out, "w"))
    c.close()


main()
