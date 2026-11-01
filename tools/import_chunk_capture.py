#!/usr/bin/env python3
"""Turn captured vanilla level_chunk_with_light packets into COPY streams for the mc.* tables, so a test can load real terrain and re-encode it.

usage: tools/import_chunk_capture.py KIND [CAPTURE.jsonl]
  KIND: chunks | sections | light | entities | expected
  CAPTURE default: $DBCRAFT_TERRAIN_CAPTURE, else /tmp/dbcraft-fixtures/terrain_nocomp.jsonl
Prints nothing when the capture is missing, so callers can skip.  Chunks go into dimension 'dbcraft:terrain'.
Palettes are stored exactly as sent (order, bit width, packed longs); ids are resolved to names with the generator reports and the captured registry_data.
`expected` prints the captured packet with its heightmap entries put into the order mc.heightmaps_wire writes (vanilla's order is a hash-map order that varies
between JVM runs), so the comparison is byte for byte.
Not used by the server; test tooling only.  The capture is Mojang data and stays outside git.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _capture as C

kind = sys.argv[1]
path = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("DBCRAFT_TERRAIN_CAPTURE", "/tmp/dbcraft-fixtures/terrain_nocomp.jsonl")
if not os.path.exists(path):
    sys.exit(0)
DIM = "dbcraft:terrain"
OUR_ORDER = [4, 5, 1]            # MOTION_BLOCKING, MOTION_BLOCKING_NO_LEAVES, WORLD_SURFACE: the order mc.heightmaps_wire writes
HM_COL = {4: 0, 5: 1, 1: 2}
states = C.state_names()
biomes = C.registry_names(path)["minecraft:worldgen/biome"]
import json
BE_TYPE = {i["protocol_id"]: n for n, i in json.load(open(os.path.join(os.environ.get("DBCRAFT_REPORTS", C.DEFAULT_REPORTS), "registries.json")))["minecraft:block_entity_type"]["entries"].items()}


def arr(items):
    return "{" + ",".join('"' + i + '"' for i in items) + "}"


def bytea(b):
    return "\\\\x" + b.hex()


chunks = []
for rec, b in C.packets(path, "minecraft:level_chunk_with_light"):
    chunks.append((b, C.parse_chunk(b)))

for b, c in chunks:
    cx, cz = c["cx"], c["cz"]
    if kind == "chunks":
        by_type = {k: C.unpack(vals, 9, 256) for k, vals, _ in c["hms"]}
        cols = [by_type[k] for k in (4, 5, 1)]
        print("\t".join([DIM, str(cx), str(cz)] + ["{" + ",".join(map(str, col)) + "}" for col in cols] + ["f"]))
    elif kind == "sections":
        for i, s in enumerate(c["secs"]):
            sy = -4 + i
            pal = [states[x] for x in s["pal"]] if s["pal"] is not None else []
            bpal = [biomes[x] for x in s["bpal"]] if s["bpal"] is not None else []
            print("\t".join([DIM, str(cx), str(cz), str(sy), str(s["count"]), str(s["fluid"]), arr(pal), str(s["bits"]), bytea(s["data"]),
                             arr(bpal), str(s["bbits"]), bytea(s["bdata"])]))
    elif kind == "light":
        sky_idx, blk_idx, sky_empty, blk_empty = c["masks"]
        sky = dict(zip(sky_idx, c["sky"])); blk = dict(zip(blk_idx, c["blk"]))
        for idx in sorted(set(sky_idx) | set(blk_idx) | set(sky_empty) | set(blk_empty)):
            sk = "data" if idx in sky else ("empty" if idx in sky_empty else None)
            bk = "data" if idx in blk else ("empty" if idx in blk_empty else None)
            print("\t".join([DIM, str(cx), str(cz), str(idx), sk or "\\N", bytea(sky[idx]) if idx in sky else "\\N", bk or "\\N", bytea(blk[idx]) if idx in blk else "\\N"]))
    elif kind == "entities":
        for e in c["bes"]:
            x = cx * 16 + (e["packed"] >> 4); z = cz * 16 + (e["packed"] & 15)
            name = BE_TYPE[e["type"]]
            print("\t".join([DIM, str(cx), str(cz), str(x), str(e["y"]), str(z), name, bytea(e["nbt"])]))
    elif kind == "expected":
        by_type = {k: raw for k, _, raw in c["hms"]}
        head = b[:c["hm_start"]]
        count = bytes([len(OUR_ORDER)])
        body = head + count + b"".join(by_type[k] for k in OUR_ORDER) + b[c["hm_end"]:]
        assert len(body) == len(b)
        print(f"{cx}\t{cz}\t{body.hex()}")
