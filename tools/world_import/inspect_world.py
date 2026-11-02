#!/usr/bin/env python3
"""Print the structure of a vanilla world: one chunk's key tree, level.dat, player data, and the block entity types present.
usage: tools/world_import/inspect_world.py WORLD_DIR [chunk_x chunk_z]"""
import collections, gzip, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import anvil as A


def show(v, depth=0, maxd=3, key="", out=None):
    pad = "  " * depth
    if isinstance(v, dict):
        print(f"{pad}{key}{{}} ({len(v)} keys)")
        if depth < maxd:
            for k, x in v.items():
                show(x, depth + 1, maxd, k + ": ")
    elif isinstance(v, A.ListTag):
        print(f"{pad}{key}list<{v.etype}> x{len(v)}")
        if depth < maxd and len(v):
            show(v[0], depth + 1, maxd, "[0] ")
    elif isinstance(v, (A.LongArray, A.IntArray, A.ByteArray)):
        print(f"{pad}{key}{type(v).__name__}[{len(v)}]")
    else:
        s = repr(v)
        print(f"{pad}{key}{type(v).__name__} {s[:70]}")


world = sys.argv[1]
print("== level.dat")
with open(os.path.join(world, "level.dat"), "rb") as f:
    n, v = A.parse_nbt(gzip.decompress(f.read()))
show(v, maxd=4)
for sub in ("data", "dimensions/minecraft/overworld/data"):
    p = os.path.join(world, sub)
    for root, _, files in os.walk(p):
        for fn in files:
            print("data file:", os.path.relpath(os.path.join(root, fn), world))
pdir = os.path.join(world, "players", "data")
if os.path.isdir(pdir):
    for fn in sorted(os.listdir(pdir))[:1]:
        print("== player", fn)
        with open(os.path.join(pdir, fn), "rb") as f:
            n, v = A.parse_nbt(gzip.decompress(f.read()))
        show(v, maxd=2)
region = os.path.join(world, "dimensions", "minecraft", "overworld", "region")
cx0 = int(sys.argv[2]) if len(sys.argv) > 3 else 0
cz0 = int(sys.argv[3]) if len(sys.argv) > 3 else 0
types = collections.Counter()
statuses = collections.Counter()
found = None
nch = 0
for p in A.region_files(region):
    for cx, cz, raw in A.read_region(p):
        nch += 1
        n, c = A.parse_nbt(raw)
        statuses[str(c.get("Status"))] += 1
        for be in c.get("block_entities", []):
            types[str(be.get("id"))] += 1
        if (cx, cz) == (cx0, cz0):
            found = c
print("== chunks:", nch, dict(statuses))
print("== block entity types:", dict(types))
if found is not None:
    print(f"== chunk {cx0},{cz0}")
    show(found, maxd=3)
    s = found["sections"][8]
    print("== section sample", {k: (v if not isinstance(v, (A.LongArray, A.ByteArray)) else f"{type(v).__name__}[{len(v)}]") for k, v in s.items() if k not in ("block_states", "biomes")})
    print("block_states", {k: (v[:6] if isinstance(v, list) else v) for k, v in s["block_states"].items() if k == "palette"}, "data len", len(s["block_states"].get("data", [])))
    print("biomes", dict(s["biomes"]))
    print("section Ys", [x["Y"] for x in found["sections"]])
