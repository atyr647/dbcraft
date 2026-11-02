#!/usr/bin/env python3
"""Load the opaque play-entry packets (net.static_packet) from a capture of a vanilla server.

usage: tools/load_static_packets.py [CAPTURE.jsonl]     (default: newest tests/fixtures/captured/play*.jsonl here or in the parent checkout)
Connection: libpq environment or DBCRAFT_PSQL.

These are the packets whose contents are not yet generated from readable rows: update_recipes, commands, recipe_book_add,
update_advancements, and the player's own set_entity_data / update_attributes (stored without the entity id, which is added per player).
They are Mojang data read from your own server at load time; they are never committed.  See docs/NET.md for what replaces them.
"""
import glob, json, os, subprocess, sys

here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()
# name -> (ord in net.play_entry_packets, body starts with the player's entity id)
WANT = {"minecraft:update_recipes": (50, False), "minecraft:commands": (70, False), "minecraft:recipe_book_add": (90, False),
        "minecraft:set_entity_data": (230, True), "minecraft:update_attributes": (240, True), "minecraft:update_advancements": (250, False)}

def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 127) << s
        if not c & 128: return v, o
        s += 7

if len(sys.argv) > 1: cap = sys.argv[1]
else:
    c = [p for d in __import__("_capture").capture_dirs() for p in glob.glob(os.path.join(d, "play*.jsonl"))]
    if not c: sys.exit("no capture found: run tools/bootstrap.sh (it records one from the vanilla server) or tools/capture_vanilla.py")
    cap = max(c, key=os.path.getmtime)
rows = [json.loads(l) for l in open(cap)]
play = [r for r in rows if r["state"] == "play" and r["dir"] == "clientbound"]
login = next(r for r in play if r["name"] == "minecraft:login")
lw = bytes.fromhex(login["hex"]); _, o = vi(lw, 0); _, o = vi(lw, o); entity_id = int.from_bytes(lw[o:o + 4], "big")
found = {}
for r in play:
    n = r["name"]
    if n in WANT and n not in found:
        w = bytes.fromhex(r["hex"]); _, o = vi(w, 0); _, o = vi(w, o); body = w[o:]
        if WANT[n][1]:
            eid, o2 = vi(body, 0)
            if eid != entity_id: continue          # someone else's entity: keep looking for the player's own
            body = body[o2:]
        found[n] = body
missing = set(WANT) - set(found)
if missing: sys.exit(f"{cap}: missing packets {sorted(missing)}")
sql = "TRUNCATE net.static_packet; " + "".join(
    f"INSERT INTO net.static_packet (seq, ord, packet, entity_prefixed, body, note) VALUES ({i}, {WANT[n][0]}, '{n}', {str(WANT[n][1]).lower()}, "
    f"'\\x{found[n].hex()}', 'captured from a vanilla 26.3 server: creative player, flat world');" for i, n in enumerate(sorted(found, key=lambda k: WANT[k][0]), 1))
p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql.encode(), capture_output=True)
if p.returncode: sys.exit(p.stderr.decode())
print(f"loaded {len(found)} opaque packets ({sum(len(b) for b in found.values())} bytes) from {cap}")
