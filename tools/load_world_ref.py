#!/usr/bin/env python3
"""Load the data-driven registry ids the world needs (biomes, dimension types) into mc.biome / mc.dimension_type.

usage: tools/load_world_ref.py [CAPTURE.jsonl]
       default capture: $DBCRAFT_CAPTURE, else /home/user/dbcraft/tests/fixtures/captured/play_nocomp.jsonl
Reads the configuration-phase minecraft:registry_data packets recorded by tools/capture_vanilla.py: each carries a registry id and the entry keys
in id order, so the id of an entry is its position.  Connection settings come from the libpq environment (or DBCRAFT_PSQL).
Exit status 3 (and a message) when the capture is missing, so callers can skip.  Standard library only; nothing is written to the repository.
"""
import json, os, struct, subprocess, sys

path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DBCRAFT_CAPTURE", "/home/user/dbcraft/tests/fixtures/captured/play_nocomp.jsonl")
if not os.path.exists(path):
    print(f"no capture at {path}", file=sys.stderr)
    sys.exit(3)
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()


def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1
        v |= (c & 127) << s
        if c < 128:
            return v, o
        s += 7


def skip(b, o, t):
    """Skip one NBT payload of tag type t."""
    fixed = {1: 1, 2: 2, 3: 4, 4: 8, 5: 4, 6: 8}
    if t in fixed: return o + fixed[t]
    if t == 7: return o + 4 + struct.unpack(">i", b[o:o + 4])[0]
    if t == 8: return o + 2 + struct.unpack(">H", b[o:o + 2])[0]
    if t == 9:
        et = b[o]; n = struct.unpack(">i", b[o + 1:o + 5])[0]; o += 5
        for _ in range(n): o = skip(b, o, et)
        return o
    if t == 10:
        while b[o] != 0:
            nt = b[o]; nl = struct.unpack(">H", b[o + 1:o + 3])[0]; o += 3 + nl; o = skip(b, o, nt)
        return o + 1
    if t == 11: return o + 4 + 4 * struct.unpack(">i", b[o:o + 4])[0]
    if t == 12: return o + 4 + 8 * struct.unpack(">i", b[o:o + 4])[0]
    raise ValueError(f"nbt tag {t}")


wanted = {"minecraft:worldgen/biome": "mc.biome", "minecraft:dimension_type": "mc.dimension_type"}
found = {}
for line in open(path):
    r = json.loads(line)
    if r["name"] != "minecraft:registry_data" or r["dir"] != "clientbound":
        continue
    b = bytes.fromhex(r["hex"])
    _, o = vi(b, 0); _, o = vi(b, o)                      # frame length, packet id
    ln, o = vi(b, o); reg = b[o:o + ln].decode(); o += ln
    if reg not in wanted:
        continue
    n, o = vi(b, o); names = []
    for _ in range(n):
        l2, o = vi(b, o); names.append(b[o:o + l2].decode()); o += l2
        has = b[o]; o += 1
        if has:
            assert b[o] == 10, "entry data is not a compound"
            o = skip(b, o + 1, 10)
    found[reg] = names

rows = "".join(f"{wanted[reg]}\t{i}\t{name}\n" for reg, names in found.items() for i, name in enumerate(names))
sql = ("create temp table _wr (tbl text, id int, name text); copy _wr from stdin; "
       "truncate mc.biome, mc.dimension_type; "
       "insert into mc.biome select name, id from _wr where tbl = 'mc.biome'; "
       "insert into mc.dimension_type select name, id from _wr where tbl = 'mc.dimension_type';")
p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", "create temp table _wr (tbl text, id int, name text)",
                           "-c", "\\copy _wr from stdin", "-c", "truncate mc.biome, mc.dimension_type",
                           "-c", "insert into mc.biome select name, id from _wr where tbl = 'mc.biome'",
                           "-c", "insert into mc.dimension_type select name, id from _wr where tbl = 'mc.dimension_type'"],
                   input=rows.encode(), capture_output=True)
if p.returncode:
    sys.exit(p.stderr.decode())
print(f"loaded {len(found.get('minecraft:worldgen/biome', []))} biomes, {len(found.get('minecraft:dimension_type', []))} dimension types from {path}")
