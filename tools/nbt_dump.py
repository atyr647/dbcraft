#!/usr/bin/env python3
"""Decode network NBT (nameless root, as in 26.x packets) from hex and print it as an ordered tree.  Used to learn exact key order of vanilla text components.
usage: tools/nbt_dump.py HEX [OFFSET]      (OFFSET = byte offset of the NBT root inside the hex; default 0)
       tools/nbt_dump.py --packet CAPTURE.jsonl MARK_FROM NAME [N]   dump the Nth (default first) packet NAME after the mark, skipping the frame header + packet id
"""
import json, struct, sys

TAGS = {1: "byte", 2: "short", 3: "int", 4: "long", 5: "float", 6: "double", 7: "byte_array", 8: "string", 9: "list", 10: "compound", 11: "int_array", 12: "long_array"}

class R:
    def __init__(self, b, o=0): self.b, self.o = b, o
    def take(self, n): v = self.b[self.o:self.o + n]; self.o += n; return v
    def u16(self): return struct.unpack(">H", self.take(2))[0]
    def i32(self): return struct.unpack(">i", self.take(4))[0]

def payload(r, t, ind):
    if t == 1: return struct.unpack(">b", r.take(1))[0]
    if t == 2: return struct.unpack(">h", r.take(2))[0]
    if t == 3: return r.i32()
    if t == 4: return struct.unpack(">q", r.take(8))[0]
    if t == 5: return struct.unpack(">f", r.take(4))[0]
    if t == 6: return struct.unpack(">d", r.take(8))[0]
    if t == 8: return json.dumps(r.take(r.u16()).decode("utf-8", "replace"))
    if t == 7: n = r.i32(); return "bytes[%d]" % n if r.take(n) is not None else None
    if t == 11: n = r.i32(); [r.take(4) for _ in range(n)]; return "ints[%d]" % n
    if t == 12: n = r.i32(); [r.take(8) for _ in range(n)]; return "longs[%d]" % n
    if t == 9:
        et = r.take(1)[0]; n = r.i32(); out = [f"list<{TAGS.get(et, et)}>[{n}]"]
        for _ in range(n): out.append(("\n" + "  " * (ind + 1)) + str(payload(r, et, ind + 1)))
        return "".join(out)
    if t == 10:
        out = []
        while True:
            tt = r.take(1)[0]
            if tt == 0: break
            name = r.take(r.u16()).decode()
            out.append(("\n" + "  " * (ind + 1)) + f"{name} ({TAGS.get(tt, tt)}): " + str(payload(r, tt, ind + 1)))
        return "{" + "".join(out) + "\n" + "  " * ind + "}"
    raise ValueError(f"tag {t}")

def dump(b, o=0):
    r = R(b, o); t = r.take(1)[0]
    if t == 0: return "(end)", r.o
    if t not in (8, 10): return f"root tag {t}", r.o
    return f"({TAGS[t]}) " + str(payload(r, t, 0)), r.o

if __name__ == "__main__":
    if sys.argv[1] == "--packet":
        ev = [json.loads(l) for l in open(sys.argv[2])]
        start = next(k for k, e in enumerate(ev) if e["name"] == sys.argv[3]); want = "minecraft:" + sys.argv[4]; n = int(sys.argv[5]) if len(sys.argv) > 5 else 0
        e = [x for x in ev[start:] if x["name"] == want][n]; b = bytes.fromhex(e["hex"])
        o = 0
        while b[o] & 0x80: o += 1                       # frame length varint
        o += 1
        while b[o] & 0x80: o += 1                       # packet id varint
        o += 1
        text, end = dump(b, o); print(text); print(f"-- consumed to byte {end} of {len(b)}; trailing: {b[end:].hex()}")
    else:
        text, end = dump(bytes.fromhex(sys.argv[1]), int(sys.argv[2]) if len(sys.argv) > 2 else 0); print(text)
