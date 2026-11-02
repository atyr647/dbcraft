#!/usr/bin/env python3
"""Test the explanation of the remaining block differences: chunks whose file still holds pending PostProcessing entries are updated by vanilla when it loads them.
usage: check_postprocessing.py WORLD_DIR COMPARE.json     (COMPARE.json from compare_chunks.py --json)"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "tools", "world_import"))
import anvil as A

world, cmp_json = sys.argv[1], sys.argv[2]
res = json.load(open(cmp_json))
compared = {tuple(x) for x in res["compared"]}
differ_blocks = {tuple(x) for x in res["fails"]["sections"]} | {tuple(x) for x in res["fails"]["heightmaps"]}
pending = {}
folder = os.path.join(world, "dimensions", "minecraft", "overworld", "region")
for p in A.region_files(folder):
    for cx, cz, raw in A.read_region(p):
        if (cx, cz) not in compared:
            continue
        name, c = A.parse_nbt(raw)
        pending[(cx, cz)] = sum(len(l) for l in c.get("PostProcessing", []))
with_pp = {k for k, v in pending.items() if v}
print("compared chunks: %d | with pending PostProcessing entries: %d | whose blocks/heightmaps differ from vanilla: %d" % (len(compared), len(with_pp), len(differ_blocks)))
print("differing chunks WITHOUT pending post-processing: %d %s" % (len(differ_blocks - with_pp), sorted(differ_blocks - with_pp)[:5]))
print("chunks WITH pending post-processing that are identical anyway: %d (the updates changed nothing there)" % len(with_pp - differ_blocks))
light = {tuple(x) for x in res["fails"]["light_masks"]} | {tuple(x) for x in res["fails"]["light_arrays"]}


def near(k, s, r=1):
    return any(max(abs(k[0] - e[0]), abs(k[1] - e[1])) <= r for e in s)


explained = {k for k in light if near(k, differ_blocks) or near(k, with_pp)}
print("chunks whose light differs: %d | next to a chunk with differing blocks or pending post-processing (light crosses chunk borders): %d | not explained: %d %s"
      % (len(light), len(explained), len(light - explained), sorted(light - explained)[:6]))
sys.exit(0 if not (differ_blocks - with_pp) else 1)
