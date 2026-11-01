#!/usr/bin/env python3
"""List the packets of a game_probe capture between two marks, hiding noise.

usage: tools/cap_view.py CAPTURE.jsonl [FROM_MARK [TO_MARK]] [--names a,b] [--all] [--width 230]
Marks are the labels game_probe records ("bob joins", "bob moves", "cmd list" ...); with no marks the whole file is listed.
"""
import json, sys
a = sys.argv[1:]; width = 230; names = None; show_all = False; pos = []
i = 0
while i < len(a):
    if a[i] == "--width": width = int(a[i + 1]); i += 2
    elif a[i] == "--names": names = set("minecraft:" + n for n in a[i + 1].split(",")); i += 2
    elif a[i] == "--all": show_all = True; i += 1
    else: pos.append(a[i]); i += 1
ev = [json.loads(l) for l in open(pos[0])]
lo = next((k for k, e in enumerate(ev) if len(pos) > 1 and e["name"] == pos[1]), 0)
hi = next((k for k, e in enumerate(ev) if len(pos) > 2 and e["name"] == pos[2] and k > lo), len(ev))
noise = {"minecraft:level_chunk_with_light", "minecraft:chunk_batch_start", "minecraft:chunk_batch_finished", "minecraft:set_time", "minecraft:keep_alive", "minecraft:bundle_delimiter"}
for e in ev[lo:hi]:
    if names is not None and e["name"] not in names and e["state"] != "mark": continue
    if not show_all and e["name"] in noise: continue
    print(f'{e["t"]:7.3f} {e["name"].replace("minecraft:", ""):26s} {len(e["hex"]) // 2:4d}  {e["hex"][:width]}')
