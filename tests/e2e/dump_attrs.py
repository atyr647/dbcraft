#!/usr/bin/env python3
"""Scratch helper: decode every update_attributes of a recording (entity, attribute id, base, modifiers) -- shows the order of the modifiers the real server sends."""
import json, struct, sys

def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << s
        if not c & 0x80: return v, o
        s += 7

for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["state"] == "mark": print("## " + e["name"]); continue
    if e["dir"] != "clientbound" or e["name"] != "minecraft:update_attributes" or e["state"] != "play": continue
    raw = bytes.fromhex(e["hex"]); _, o = vi(raw, 0); _, o = vi(raw, o)
    eid, o = vi(raw, o); n, o = vi(raw, o); out = []
    for _ in range(n):
        aid, o = vi(raw, o); base = struct.unpack(">d", raw[o:o + 8])[0]; o += 8; m, o = vi(raw, o); mods = []
        for _ in range(m):
            ln, o = vi(raw, o); nm = raw[o:o + ln].decode(); o += ln; amt = struct.unpack(">d", raw[o:o + 8])[0]; o += 8; op = raw[o]; o += 1
            mods.append(f"{nm.split(':')[1]}={amt}/{op}")
        out.append(f"{aid}:{base:g}[{','.join(mods)}]")
    print(f"  {eid}: " + " ".join(out))
