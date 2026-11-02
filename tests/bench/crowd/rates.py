#!/usr/bin/env python3
"""How many packets does a server send an OBSERVER about a WALKER?  Run against the real vanilla server and a dbcraft database, same scenario, and compare.

usage: tests/bench/crowd/rates.py --port PORT [--host 127.0.0.1] [--seconds 10] [--mode straight|turning|stand] [--label NAME]
The walker sends, every 50 ms: client_tick_end + move_player_pos (straight: +0.215 blocks/tick = 4.3 blocks/s east; turning: move_player_pos_rot with the yaw
turning 3 degrees per tick; stand: only client_tick_end).  The observer stays where it is.  After 2 s of settling, packets that name the walker's entity are
counted per type for --seconds, with their byte sizes, the per-second rate, and the distribution of the `ticks` field of move_entity_pos(_rot).
Layouts (26.3): move_entity_pos = VarInt entity id, VarInt ticks?, ...: read from the class bytecode in docs/PERF-CROWD.md; here only the leading VarInt (entity id) is used.
"""
import argparse, collections, json, os, struct, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "e2e"))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, required=True)
ap.add_argument("--seconds", type=float, default=10.0)
ap.add_argument("--mode", choices=["straight", "turning", "stand"], default="straight")
ap.add_argument("--label", default="")
ap.add_argument("--json", default="")
a = ap.parse_args()

obs = m.Client(a.host, a.port, "Obs" + str(os.getpid() % 1000))
obs.settle(1.0, 15.0)
walker = m.Client(a.host, a.port, "Wlk" + str(os.getpid() % 1000))
walker.settle(1.0, 15.0)
obs.settle(1.0, 5.0)
x, y, z = walker.pos
yaw = 0.0
MOVE = ("minecraft:move_entity_pos", "minecraft:move_entity_pos_rot", "minecraft:move_entity_rot", "minecraft:rotate_head",
        "minecraft:entity_position_sync", "minecraft:teleport_entity", "minecraft:set_entity_motion", "minecraft:set_entity_data",
        "minecraft:update_attributes", "minecraft:entity_event", "minecraft:animate", "minecraft:set_equipment")

# which entity id is the walker?  the add_entity the observer received for it (first VarInt after nothing: add_entity = VarInt id, UUID ...)
walker_uuid = None
eid = None
for e in obs.events:
    if e["name"] == "minecraft:add_entity":
        eid = m.parse_varint(e["body"], 0)[0]
if eid is None:
    sys.exit("the observer never saw the walker spawn (add_entity)")

start_n = obs.count()
t0 = time.time()
tick = 0
next_t = t0
while time.time() - t0 < a.seconds:
    walker.send("minecraft:client_tick_end")
    if a.mode == "straight":
        x += 0.215
        walker.send("minecraft:move_player_pos", struct.pack(">ddd", x, y, z) + b"\x01")
    elif a.mode == "turning":
        x += 0.215; yaw = (yaw + 3.0) % 360
        walker.send("minecraft:move_player_pos_rot", struct.pack(">dddff", x, y, z, yaw, 0.0) + b"\x01")
    tick += 1
    next_t += 0.05
    time.sleep(max(0.0, next_t - time.time()))
obs.settle(0.3, 3.0)

counts = collections.Counter(); size = collections.Counter(); ticks_field = collections.Counter(); per_sec = collections.defaultdict(collections.Counter)
for e in obs.events[start_n:]:
    if e["name"] in MOVE and e["dir"] == "clientbound":
        body = e["body"]
        if m.parse_varint(body, 0)[0] != eid:
            continue
        n = e["name"].replace("minecraft:", "")
        counts[n] += 1; size[n] += len(e["hex"]) // 2
        per_sec[int(e["t"] - obs.events[start_n]["t"])][n] += 1
        if n in ("move_entity_pos", "move_entity_pos_rot"):
            o = m.parse_varint(body, 0)[1]
            # 26.3 move_entity_pos: VarInt id, then the fields; the ticks VarInt follows the flags byte in dbcraft's builder: read both candidates
            ticks_field[body[o + 1] if len(body) > o + 1 else -1] += 1
if os.environ.get("RATES_DUMP"):
    t_first = None
    shown = 0
    for e in obs.events[start_n:]:
        if e["name"] in MOVE and e["dir"] == "clientbound" and m.parse_varint(e["body"], 0)[0] == eid and shown < 14:
            t_first = t_first or e["t"]
            print(f"    +{(e['t'] - t_first) * 1000:7.1f} ms  {e['name'].replace('minecraft:', ''):24s} {e['body'].hex()}")
            shown += 1
secs = a.seconds
print(f"[{a.label or a.port}] mode={a.mode} walker eid={eid} {a.seconds:.0f} s, {tick} client ticks sent")
tot = 0; totb = 0
for n in sorted(counts):
    print(f"  {n:32s} {counts[n]:5d} packets  {counts[n] / secs:6.2f}/s  {size[n]:7d} bytes  ({size[n] / counts[n]:.1f} B each)")
    tot += counts[n]; totb += size[n]
print(f"  {'TOTAL about the walker':32s} {tot:5d} packets  {tot / secs:6.2f}/s  {totb:7d} bytes  = {tot / tick:.2f} packets per client tick")
print(f"  second byte after the id in move packets (flags/ticks candidates): {dict(ticks_field)}")
if a.json:
    json.dump({"label": a.label, "mode": a.mode, "seconds": secs, "client_ticks": tick, "packets": counts, "bytes": size}, open(a.json, "w"))
obs.close() if hasattr(obs, "close") else None
walker.close() if hasattr(walker, "close") else None
