#!/usr/bin/env python3
"""Print the on-disk block entity compounds of one type found in a world (to derive the chunk packet's update tag).  usage: peek_be.py WORLD_DIR TYPE [n]"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import anvil as A

world, typ = sys.argv[1], sys.argv[2]
want = int(sys.argv[3]) if len(sys.argv) > 3 else 2
folder = os.path.join(world, "dimensions", "minecraft", "overworld", "region")
seen = 0
for p in A.region_files(folder):
    for cx, cz, raw in A.read_region(p):
        i = raw.find(b"\x08\x00\x06Status", 0, 400)
        if i >= 0 and raw[i + 11:i + 11 + 14] != b"minecraft:full":
            continue
        name, c = A.parse_nbt(raw)
        for be in c.get("block_entities", []):
            if str(be.get("id")) == typ:
                print(cx, cz, repr(be)[:700])
                seen += 1
                if seen >= want:
                    sys.exit(0)
