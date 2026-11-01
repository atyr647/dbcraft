#!/usr/bin/env python3
"""One client walks east across chunk borders; what the server sends for chunk streaming is recorded and summarised.  Run against the real vanilla
server to learn the layout, and against a dbcraft database to compare.

usage: tests/e2e/move_probe.py [--host 127.0.0.1] [--port 25599] [--name Walker] [--out /tmp/dbcraft-e2e/move_vanilla] [--steps 4]
Each step is: client_tick_end, then move_player_pos moving +8 blocks east (the real server accepts at most 10 per packet, and two position packets with no
client_tick_end between them get the player disconnected).
Prints, per step, the set_chunk_cache_center / chunk batch / forget_level_chunk packets received and the chunk coordinates in them.
Layouts: set_chunk_cache_center = VarInt x, VarInt z.  forget_level_chunk = one long (ChunkPos.toLong: low 32 bits x, high 32 bits z).
level_chunk_with_light starts with int x, int z.  chunk_batch_finished = VarInt count.
"""
import argparse, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25599)
ap.add_argument("--name", default="Walker"); ap.add_argument("--out", default="/tmp/dbcraft-e2e/move_vanilla")
ap.add_argument("--steps", type=int, default=4)
a = ap.parse_args()
os.makedirs(os.path.dirname(a.out), exist_ok=True)

c = m.Client(a.host, a.port, a.name)
c.settle(1.0, 15.0)
x, y, z = c.pos
print(f"start {c.pos}, chunk {int(x // 16)},{int(z // 16)}; chunk packets so far: {len(c.since(0, {'minecraft:level_chunk_with_light'}))}")

KINDS = {"minecraft:set_chunk_cache_center", "minecraft:chunk_batch_start", "minecraft:chunk_batch_finished", "minecraft:forget_level_chunk", "minecraft:level_chunk_with_light"}
for step in range(a.steps):
    k = c.count()
    x += 8.0
    c.mark(f"step {step + 1}: to x={x}")
    c.send("minecraft:client_tick_end")
    c.send("minecraft:move_player_pos", struct.pack(">ddd", x, y, z) + b"\x01")
    c.settle(0.8, 6.0)
    got = c.since(k, KINDS)
    centers = [m.parse_varint(e["body"], 0)[0] for e in got if e["name"] == "minecraft:set_chunk_cache_center"]
    chunks = [struct.unpack(">ii", e["body"][:8]) for e in got if e["name"] == "minecraft:level_chunk_with_light"]
    forgets = [struct.unpack(">ii", e["body"][:8]) for e in got if e["name"] == "minecraft:forget_level_chunk"]
    fin = [m.parse_varint(e["body"])[0] for e in got if e["name"] == "minecraft:chunk_batch_finished"]
    order = [e["name"].replace("minecraft:", "") for e in got if e["name"] != "minecraft:level_chunk_with_light"]
    print(f"step {step + 1}: x={x}: order={order} chunks_sent={len(chunks)} finished={fin}")
    for e in got:
        if e["name"] in ("minecraft:set_chunk_cache_center", "minecraft:forget_level_chunk", "minecraft:chunk_batch_finished"):
            print(f"    {e['name'].replace('minecraft:', '')}: {e['body'].hex()}")
    if chunks: print(f"    chunks x in {sorted(set(cx for cx, cz in chunks))}  z in {sorted(set(cz for cx, cz in chunks))}  first {chunks[:3]}")
    if forgets: print(f"    forgot (as the two ints in the body: first, second): {forgets[:4]} ... {len(forgets)} total")
c.dump(a.out + ".jsonl")
print("recorded", a.out + ".jsonl")
c.close()
