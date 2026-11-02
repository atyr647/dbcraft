#!/usr/bin/env python3
"""Print distinct shapes of block-state palette entries found in a world (26.3 changed the entry format).  usage: peek_palette.py WORLD_DIR [max_chunks]"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import anvil as A

world = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 200
folder = os.path.join(world, "dimensions", "minecraft", "overworld", "region")
shapes = {}
n = 0
for p in A.region_files(folder):
    for cx, cz, raw in A.read_region(p):
        name, c = A.parse_nbt(raw)
        if str(c.get("Status")) != "minecraft:full":
            continue
        n += 1
        for s in c.get("sections", []):
            for e in s.get("block_states", {}).get("palette", []):
                key = tuple(sorted(e.keys())) if isinstance(e, dict) else type(e).__name__
                if key not in shapes or (isinstance(e, dict) and len(e) > len(shapes[key])):
                    shapes[key] = e
        if n >= limit:
            break
    if n >= limit:
        break
for k, e in sorted(shapes.items(), key=lambda kv: str(kv[0]))[:12]:
    print(k, "->", e)
