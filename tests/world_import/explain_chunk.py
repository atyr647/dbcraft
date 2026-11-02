#!/usr/bin/env python3
"""Explain how the light masks and block entities of one chunk differ between vanilla's packet and dbcraft's.
usage: tests/world_import/explain_chunk.py CAPTURE.jsonl CX CZ"""
import json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "world_import"))
import _capture as C
import anvil as A

cap, cx, cz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
PSQL = os.environ.get("DBCRAFT_PSQL", "psql").split()
vp = next(b for r, b in C.packets(cap, "minecraft:level_chunk_with_light") if C.parse_chunk(b)["cx"] == cx and C.parse_chunk(b)["cz"] == cz)
hx = subprocess.run(PSQL + ["-X", "-q", "-At", "-c", "select encode(mc.chunk_packet('minecraft:overworld', %d, %d), 'hex')" % (cx, cz)], capture_output=True).stdout.decode().strip()
v, o = C.parse_chunk(vp), C.parse_chunk(bytes.fromhex(hx))
reg = json.load(open(os.path.join(os.environ.get("DBCRAFT_REPORTS", C.DEFAULT_REPORTS), "registries.json")))["minecraft:block_entity_type"]["entries"]
be_name = {i["protocol_id"]: n for n, i in reg.items()}
print("light masks (sky, block, empty sky, empty block): layer indexes")
for name, vm, om in zip(("sky", "block", "emptySky", "emptyBlock"), v["masks"], o["masks"]):
    print("  %-10s vanilla %s\n  %-10s dbcraft %s" % (name, vm, "", om))
print("sky arrays: vanilla %d dbcraft %d | block arrays: vanilla %d dbcraft %d" % (len(v["sky"]), len(o["sky"]), len(v["blk"]), len(o["blk"])))


def bes(c):
    out = {}
    for e in c["bes"]:
        tag = None if e["nbt"] == b"\x00" else A.parse_nbt(e["nbt"], network=True)[1]
        out[(e["packed"], e["y"])] = (be_name.get(e["type"], e["type"]), tag)
    return out


vb, ob = bes(v), bes(o)
print("block entities: vanilla %d dbcraft %d" % (len(vb), len(ob)))
for k in sorted(set(vb) | set(ob)):
    if vb.get(k) != ob.get(k):
        print("  at packed=%s y=%s\n    vanilla: %s\n    dbcraft: %s" % (k[0], k[1], repr(vb.get(k))[:300], repr(ob.get(k))[:300]))
