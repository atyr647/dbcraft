#!/usr/bin/env python3
"""light_update packets as one client sees them: a scripted client joins a flat world, edits change blocks next to the border of what the client tracks (vanilla sends
light_update only to players for whom the chunk is on the border of the tracked square, ChunkHolder.broadcastChanges), every light_update and block packet is recorded.
Run it against the REAL vanilla 26.3 server (edits over RCON) and against dbcraft (SQL through psql) with the same steps, then compare with tests/e2e/compare_light.py.

usage:
  vanilla:  light_probe.py --mode vanilla --port 25870 --rcon 25871 --rcon-pw lt-light --out /tmp/x/vanilla_light.json
  dbcraft:  light_probe.py --mode dbcraft --port 25872 --psql 'psql -X -At -h /tmp -p 56852 -U postgres dbcraft' --out /tmp/x/ours_light.json
The client stands in chunk (0, 0); the tracked square is chunks -3 .. 3 (view distance 2 + 1), the edits are in chunks 3 (the border), 2 (inside) and 4 (outside).
"""
import argparse, json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

DIM = "minecraft:overworld"
KEEP = ("minecraft:light_update", "minecraft:block_update", "minecraft:section_blocks_update", "minecraft:level_chunk_with_light", "minecraft:forget_level_chunk")
SLAB = "minecraft:oak_slab[type=top,waterlogged=false]"

# (label, kind, args).  The flat world has bedrock at y = -64, dirt below the grass at y = -61, air from y = -60.
STEPS = [
    ("torch on the border chunk", "set", (56, -60, 8, "minecraft:torch")),
    ("torch next to the border of two border chunks", "set", (63, -60, 8, "minecraft:torch")),
    ("glowstone in the air", "set", (56, -55, 24, "minecraft:glowstone")),
    ("glowstone at a section border (y = -49 | -48)", "set", (56, -49, 40, "minecraft:glowstone")),
    ("torch removed", "set", (56, -60, 8, "minecraft:air")),
    ("stone column of 10 blocks", "fill", (56, -60, -8, 56, -51, -8, "minecraft:stone")),
    ("stone column removed", "fill", (56, -60, -8, 56, -51, -8, "minecraft:air")),
    ("a hole in the ground", "fill", (57, -63, -24, 57, -61, -24, "minecraft:air")),
    ("a roof of 5 x 5", "fill", (54, -57, 14, 58, -57, 18, "minecraft:stone")),
    ("the roof removed", "fill", (54, -57, 14, 58, -57, 18, "minecraft:air")),
    ("a slab and a torch under it", "batch", [(56, -58, 30, SLAB), (56, -59, 30, "minecraft:torch")]),
    ("inside the tracked square: a torch in chunk 2", "set", (40, -60, 8, "minecraft:torch")),
    ("outside: a glowstone in chunk 4", "set", (72, -60, 8, "minecraft:glowstone")),
    ("negative side: a torch in chunk -3", "set", (-40, -60, -40, "minecraft:torch")),
    ("a lantern-like emitter in the corner chunk (3, 3)", "set", (56, -58, 56, "minecraft:sea_lantern")),
]


def sql_for(kind, args):
    if kind == "set":
        x, y, z, b = args
        return f"select mc.set_block('{DIM}', {x}, {y}, {z}, '{b}')"
    if kind == "fill":
        x1, y1, z1, x2, y2, z2, b = args
        return f"select mc.fill('{DIM}', {x1}, {y1}, {z1}, {x2}, {y2}, {z2}, '{b}')"
    xs = ",".join(str(a[0]) for a in args); ys = ",".join(str(a[1]) for a in args); zs = ",".join(str(a[2]) for a in args)
    bs = ",".join("'%s'" % a[3] for a in args)
    return f"select mc.set_blocks('{DIM}', array[{xs}], array[{ys}], array[{zs}], array[{bs}]::text[])"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["vanilla", "dbcraft"], required=True)
    ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--rcon", type=int); ap.add_argument("--rcon-pw", default="lt-light")
    ap.add_argument("--psql", help="psql command line for the dbcraft database")
    ap.add_argument("--out", required=True); ap.add_argument("--name", default="Lighter"); ap.add_argument("--settle", type=float, default=2.5)
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
    rc = None
    if a.mode == "vanilla":
        import common as C
        rc = C.Rcon(port=a.rcon, pw=a.rcon_pw)
    c = m.Client(a.host, a.port, a.name)
    c.settle(1.0, 15.0)
    print("client at", c.pos)
    if a.mode == "vanilla":
        print(rc.cmd("gamerule random_tick_speed 0"))
    out = []
    for label, kind, args in STEPS:
        k = c.count(); c.mark(label)
        resp = ""
        if a.mode == "vanilla":
            if kind == "set":
                x, y, z, b = args; resp = rc.cmd(f"setblock {x} {y} {z} {b}")
            elif kind == "fill":
                x1, y1, z1, x2, y2, z2, b = args; resp = rc.cmd(f"fill {x1} {y1} {z1} {x2} {y2} {z2} {b}")
            else:
                resp = " ".join(rc.cmd(f"setblock {x} {y} {z} {b}") for (x, y, z, b) in args)
        else:
            r = subprocess.run(a.psql.split() + ["-c", sql_for(kind, args)], capture_output=True, text=True)
            resp = (r.stdout + r.stderr).strip()
        time.sleep(a.settle)
        got = [e for e in c.since(k) if e["name"] in KEEP]
        out.append({"label": label, "kind": kind, "response": resp, "packets": [{"name": e["name"], "hex": e["body"].hex(), "t": e.get("t")} for e in got]})
        print(f"[{label}] {resp[:50]!r} -> " + ", ".join(f"{e['name'].replace('minecraft:', '')}({len(e['body'])}B)" for e in got))
    json.dump(out, open(a.out, "w"))
    c.close()


main()
