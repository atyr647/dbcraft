#!/usr/bin/env python3
"""Two players join one after the other, one of them chats, then the second leaves.  Everything each client receives is recorded.  Run it against the real
vanilla server and against a dbcraft database, then compare with tests/e2e/compare_social.py.

usage: tests/e2e/join_probe.py [--host 127.0.0.1] [--port 25611] [--out /tmp/dbcraft-e2e/vanilla_social] [--first Opa] [--second Bobb]
Writes <out>_first.jsonl and <out>_second.jsonl (marks: "second joins", "second chats", "second leaves").
"""
import argparse, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25611)
ap.add_argument("--out", default="/tmp/dbcraft-e2e/vanilla_social")
ap.add_argument("--first", default="Opa"); ap.add_argument("--second", default="Bobb")
a = ap.parse_args()
os.makedirs(os.path.dirname(a.out), exist_ok=True)

def chat(text):
    # chat = String | Instant (long ms) | salt long | Optional<signature> (absent) | lastSeen: VarInt offset, BitSet(20) as 3 bytes, checksum byte
    return m.string(text) + struct.pack(">q", int(time.time() * 1000)) + struct.pack(">q", 0) + b"\x00" + m.varint(0) + b"\x00\x00\x00" + b"\x00"

first = m.Client(a.host, a.port, a.first)
first.settle(1.0, 15.0)
first.mark("second joins")
second = m.Client(a.host, a.port, a.second)
second.settle(1.0, 15.0); first.settle(1.0, 5.0)
first.mark("second chats"); second.mark("second chats")
second.send("minecraft:chat", chat("hello world"))
second.settle(0.8, 5.0); first.settle(0.8, 5.0)
first.mark("second leaves")
second.close()
first.settle(1.5, 8.0)
first.dump(a.out + "_first.jsonl"); second.dump(a.out + "_second.jsonl")
print("recorded", a.out + "_first.jsonl", a.out + "_second.jsonl")
first.close()
