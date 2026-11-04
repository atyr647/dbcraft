#!/usr/bin/env python3
"""Scratch helper: sizes of the packets of a recording's join burst, and whether they equal dbcraft's static packet rows (psql in PGHOST/PGPORT)."""
import json, subprocess, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mcclient as m

def body(e):
    b = bytes.fromhex(e["hex"]); _, o = m.parse_varint(b, 0); _, o = m.parse_varint(b, o); return b[o:]

rows = {}
out = subprocess.run(["psql", "-X", "-At", "-F", "|", "-c", "select packet, encode(body, 'hex') from net.static_packet"], capture_output=True, text=True).stdout
for l in out.splitlines():
    p, h = l.split("|"); rows[p] = h
for path in sys.argv[1:]:
    print(path)
    for l in open(path):
        e = json.loads(l)
        if e["dir"] != "clientbound" or e["state"] != "play": continue
        if e["name"] in rows or e["name"] in ("minecraft:recipe_book_add", "minecraft:update_advancements"):
            b = body(e).hex()
            print(f"  {e['t']:7.3f} {e['name']:32s} {len(b) // 2:6d} bytes  static equal: {b == rows.get(e['name'])}")
