#!/usr/bin/env python3
"""Two clients (an actor and an observer) break and place blocks; every packet each receives is recorded.  Run it against the real vanilla server to
learn what it sends, and against a dbcraft database to compare.

usage: tests/e2e/block_probe.py [--host 127.0.0.1] [--port 25599] [--out /tmp/dbcraft-e2e/block_vanilla] [--actor Acta] [--observer Bert]
Writes <out>_actor.jsonl and <out>_observer.jsonl (one JSON object per packet; marks separate the steps) and prints what arrived after each step.
Layouts used (read from the 26.3 classes with tools/pkt_layout.py, confirmed by the real server accepting them):
  player_action = VarInt action (0 start destroy, 1 change destroy direction, 2 abort, 3 stop destroy, ...) | block position (long) | face (unsigned byte) | sequence VarInt
  use_item_on   = VarInt hand | block position (long) | VarInt face | 3 floats (cursor) | bool inside | bool world border hit | sequence VarInt
"""
import argparse, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25599)
ap.add_argument("--out", default="/tmp/dbcraft-e2e/block_vanilla")
ap.add_argument("--off", type=int, default=0, help="shift the working area along x (keep it within reach, a few blocks)")
ap.add_argument("--actor", default="Acta"); ap.add_argument("--observer", default="Bert")
a = ap.parse_args()
os.makedirs(os.path.dirname(a.out), exist_ok=True)

NOISE = {"minecraft:set_time", "minecraft:move_entity_pos", "minecraft:move_entity_pos_rot", "minecraft:move_entity_rot", "minecraft:rotate_head",
         "minecraft:set_entity_motion", "minecraft:entity_position_sync", "minecraft:set_entity_data", "minecraft:update_attributes",
         "minecraft:waypoint", "minecraft:recipe_book_add", "minecraft:update_advancements", "minecraft:keep_alive", "minecraft:player_info_update",
         "minecraft:entity_event", "minecraft:bundle_delimiter", "minecraft:add_entity", "minecraft:remove_entities"}

def action(act, x, y, z, face, seq):
    return m.varint(act) + m.position(x, y, z) + bytes([face]) + m.varint(seq)

def use_item_on(x, y, z, face, seq, hand=0):
    return m.varint(hand) + m.position(x, y, z) + m.varint(face) + struct.pack(">fff", 0.5, 1.0, 0.5) + b"\x00\x00" + m.varint(seq)

actor = m.Client(a.host, a.port, a.actor)
observer = m.Client(a.host, a.port, a.observer)
for c in (actor, observer):
    c.settle(1.0, 12.0)
ax, ay, az = actor.pos
bx, by, bz = int(ax // 1) + a.off, int(ay // 1) - 1, int(az // 1)
print(f"actor at {actor.pos}; block under it {bx},{by},{bz}")

steps = []
def step(label, fn):
    ka, ko = actor.count(), observer.count()
    actor.mark(label); observer.mark(label)
    fn()
    actor.settle(0.6, 4.0); observer.settle(0.6, 4.0)
    steps.append(label)
    for who, c, k in (("actor", actor, ka), ("observer", observer, ko)):
        got = [e for e in c.since(k) if e["name"] not in NOISE]
        print(f"[{label}] {who} received: " + (", ".join(f"{e['name'].replace('minecraft:', '')}({len(e['body'])}B)" for e in got) or "-"))
        for e in got:
            if e["name"] in ("minecraft:block_update", "minecraft:block_changed_ack", "minecraft:level_event", "minecraft:section_blocks_update", "minecraft:sound", "minecraft:block_destruction"):
                print(f"      {e['name'].replace('minecraft:', '')}: {e['body'].hex()}")

step("break under feet", lambda: actor.send("minecraft:player_action", action(0, bx, by, bz, 1, 1)))
step("creative slot stone", lambda: actor.send("minecraft:set_creative_mode_slot", m.i16(36) + m.stack("minecraft:stone", 1)))
step("place stone next to the hole", lambda: actor.send("minecraft:use_item_on", use_item_on(bx + 1, by, bz, 1, 2)))
step("break the placed stone", lambda: actor.send("minecraft:player_action", action(0, bx + 1, by + 1, bz, 1, 3)))
step("place again then break after stop", lambda: (actor.send("minecraft:use_item_on", use_item_on(bx + 1, by, bz, 1, 4)), time.sleep(0.3),
                                                    actor.send("minecraft:player_action", action(0, bx + 1, by + 1, bz, 1, 5)),
                                                    actor.send("minecraft:player_action", action(3, bx + 1, by + 1, bz, 1, 6))))
step("two breaks in the same tick", lambda: (actor.send("minecraft:player_action", action(0, bx + 3, by, bz, 1, 7)),
                                              actor.send("minecraft:player_action", action(0, bx + 4, by, bz, 1, 8))))
actor.dump(a.out + "_actor.jsonl"); observer.dump(a.out + "_observer.jsonl")
print("recorded", a.out + "_actor.jsonl", a.out + "_observer.jsonl")
actor.close(); observer.close()
