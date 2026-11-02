#!/usr/bin/env python3
"""Run the importer's chunk conversion in-process on one chunk of a world (for debugging with a traceback).
usage: debug_chunk.py WORLD_DIR CX CZ"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import anvil as A
import world_import as W

world, cx, cz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
W.load_ctx("minecraft:overworld")
folder = W.dimension_folder(world, "minecraft:overworld")
for p in A.region_files(folder):
    for x, z, raw in A.read_region(p):
        if (x, z) == (cx, cz):
            name, c = A.parse_nbt(raw)
            stats = {}
            rows = W.convert_chunk(cx, cz, c, W.CTX, stats)
            print({k: len(v) for k, v in rows.items()}, stats)
            print(rows["chunk"][0][:200])
            print(rows["section"][8][:300] if len(rows["section"]) > 8 else "")
            sys.exit(0)
print("chunk not found")
