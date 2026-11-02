#!/usr/bin/env python3
"""Print the captured minecraft:level_chunk_with_light packets as TSV: cx, cz, framed packet as hex.

usage: tools/extract_chunk_fixture.py [CAPTURE.jsonl]     (default: $DBCRAFT_CAPTURE, else play_nocomp.jsonl from $DBCRAFT_CAPTURES / $DBCRAFT_HOME/captures / tests/fixtures/captured)
Used by tests/sql/240_world_oracle.sql through `\\copy ... from program`.  Prints nothing when the capture is missing, so the test can skip.
The capture is Mojang data and stays outside git; this script only reads it.
"""
import json, os, struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DBCRAFT_CAPTURE") or __import__("_capture").find_capture("play_nocomp") or ""
if not os.path.exists(path):
    sys.exit(0)
for line in open(path):
    r = json.loads(line)
    if r["name"] != "minecraft:level_chunk_with_light" or r["dir"] != "clientbound":
        continue
    b = bytes.fromhex(r["hex"])
    o = 0
    while b[o] & 0x80:            # frame length VarInt
        o += 1
    o += 1
    while b[o] & 0x80:            # packet id VarInt
        o += 1
    o += 1
    cx, cz = struct.unpack(">ii", b[o:o + 8])
    print(f"{cx}\t{cz}\t{r['hex']}")
