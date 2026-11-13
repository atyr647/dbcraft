#!/usr/bin/env python3
"""Compare the light_update packets a client received for the same edits from the real vanilla server and from dbcraft (tests/e2e/light_probe.py writes both files).

usage: compare_light.py VANILLA.json OURS.json
Per step the light_update packets are compared as a set of byte strings (vanilla orders chunks by its hash maps).  A step passes when both servers sent the same packets.
Differences are decoded: chunk, the layers of the sky and block bit sets, and for equal layer sets the number of layers whose array differs.  Exit status 0 when every step matches.
"""
import json, sys


def varint(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1
        v |= (c & 127) << s; s += 7
        if not c & 128:
            return v, o


def sx(v):
    return v - (1 << 32) if v >= 1 << 31 else v


def decode(h):
    b = bytes.fromhex(h)
    x, o = varint(b, 0); z, o = varint(b, o)
    masks = []
    for _ in range(4):
        n, o = varint(b, o)
        v = int.from_bytes(b[o:o + n], "little"); o += n
        masks.append([i for i in range(64) if v >> i & 1])
    arrays = []
    for k in range(2):
        n, o = varint(b, o)
        lst = []
        for _ in range(n):
            ln, o = varint(b, o); lst.append(b[o:o + ln]); o += ln
        arrays.append(lst)
    return sx(x), sx(z), masks, arrays


def main():
    van = json.load(open(sys.argv[1])); ours = json.load(open(sys.argv[2]))
    bad = 0
    for sv, so in zip(van, ours):
        vl = sorted(p["hex"] for p in sv["packets"] if p["name"] == "minecraft:light_update")
        ol = sorted(p["hex"] for p in so["packets"] if p["name"] == "minecraft:light_update")
        ok = vl == ol
        print(("ok   " if ok else "DIFF ") + sv["label"].ljust(52) + f" vanilla {len(vl)} light_update, dbcraft {len(ol)}")
        if ok:
            continue
        bad += 1
        dv = {decode(h)[:2]: decode(h) for h in vl}; do = {decode(h)[:2]: decode(h) for h in ol}
        for key in sorted(set(dv) | set(do)):
            a, b = dv.get(key), do.get(key)
            if a is None or b is None:
                print(f"     chunk {key}: only {'vanilla' if b is None else 'dbcraft'} sent it; layers (sky data, block data, sky empty, block empty): {(a or b)[2]}")
            elif a[2] != b[2]:
                print(f"     chunk {key}: layer sets differ: vanilla {a[2]} dbcraft {b[2]}")
            else:
                nd = sum(1 for k in range(2) for x, y in zip(a[3][k], b[3][k]) if x != y)
                print(f"     chunk {key}: same layers {a[2]}, {nd} arrays differ")
    print("RESULT:", "FAIL (%d steps differ)" % bad if bad else "PASS")
    sys.exit(1 if bad else 0)


main()
