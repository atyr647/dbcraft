#!/usr/bin/env python3
"""Decode one section of vanilla's packet and of dbcraft's packet and say whether the BLOCKS agree and how the encodings differ.
usage: tests/world_import/explain_section.py CAPTURE.jsonl CX CZ SECTION_INDEX"""
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import _capture as C

cap, cx, cz, idx = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
PSQL = os.environ.get("DBCRAFT_PSQL", "psql").split()
names = C.state_names()
vp = next(b for r, b in C.packets(cap, "minecraft:level_chunk_with_light") if C.parse_chunk(b)["cx"] == cx and C.parse_chunk(b)["cz"] == cz)
hx = subprocess.run(PSQL + ["-X", "-q", "-At", "-c", "select encode(mc.chunk_packet('minecraft:overworld', %d, %d), 'hex')" % (cx, cz)], capture_output=True).stdout.decode().strip()
op = bytes.fromhex(hx)
v, o = C.parse_chunk(vp)["secs"][idx], C.parse_chunk(op)["secs"][idx]


def blocks(s):
    ids = C.unpack(s["data"], s["bits"], 4096) if s["bits"] else [0] * 4096
    pal = s["pal"]
    return [names[pal[i]] if pal is not None else names[i] for i in ids]


vb, ob = blocks(v), blocks(o)
diff = [i for i in range(4096) if vb[i] != ob[i]]
print("section %d of chunk %d,%d" % (idx, cx, cz))
for k in ("count", "fluid", "bits", "bbits"):
    print("  %-6s vanilla %-6s dbcraft %s" % (k, v[k], o[k]))
print("  palette vanilla :", [names[i] for i in (v["pal"] or [])][:12])
print("  palette dbcraft :", [names[i] for i in (o["pal"] or [])][:12])
print("  palette ids equal in order:", v["pal"] == o["pal"], "| same set of states:", sorted(v["pal"] or []) == sorted(o["pal"] or []))
print("  biome palette ids vanilla:", v["bpal"], "dbcraft:", o["bpal"], "| biome data equal:", v["bdata"] == o["bdata"])
print("  blocks differing by position: %d of 4096" % len(diff))
for i in diff[:8]:
    print("    x=%d y=%d z=%d vanilla %s | dbcraft %s" % (i & 15, i >> 8, (i >> 4) & 15, vb[i], ob[i]))
