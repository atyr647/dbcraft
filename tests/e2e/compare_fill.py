#!/usr/bin/env python3
"""Compare what a client received for the same /fill and /setblock steps from the real vanilla server and from dbcraft (tests/e2e/fill_probe.py writes both files).

usage: compare_fill.py VANILLA.json OURS.json
Per step the comparison is exact (hex of the packet body) for every section_blocks_update (as a set: vanilla orders the sections of different chunks by its hash maps) and
for the order of the sections within one chunk; block_update packets are compared as a set.  What vanilla sends and dbcraft does not is listed, not failed:
light_update (no light engine), and the random-tick block changes of a live world (grass under a stone block turns to dirt: block_update / level_event at y = -61 or
level_event 1025 etc.).  Exit status 0 when every step matches.
"""
import json, struct, sys


def sx(v, bits):
    return v - (1 << bits) if v >= 1 << (bits - 1) else v


def block_pos(h):
    v = int(h[:16], 16)
    return sx(v >> 38, 26), sx(v & 0xFFF, 12), sx((v >> 12) & 0x3FFFFFF, 26)


def section_pos(h):
    v = int(h[:16], 16)
    return sx(v >> 42, 22), sx(v & 0xFFFFF, 20), sx((v >> 20) & 0x3FFFFF, 22)


def varint(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1
        v |= (c & 127) << s; s += 7
        if not c & 128:
            return v, o


def entries(h):
    b = bytes.fromhex(h)
    n, o = varint(b, 8)
    out = []
    for _ in range(n):
        v, o = varint(b, o)
        out.append((v >> 12, v & 4095))
    return out


def main():
    van = json.load(open(sys.argv[1])); ours = json.load(open(sys.argv[2]))
    bad = 0
    tot = {"sbu": 0, "bu": 0, "entries": 0}
    for sv, so in zip(van, ours):
        assert sv["label"] == so["label"]
        msgs, notes = [], []
        def pick(step, name):
            return [p["hex"] for p in step["packets"] if p["name"] == name]
        vs, os_ = pick(sv, "minecraft:section_blocks_update"), pick(so, "minecraft:section_blocks_update")
        # a live vanilla world also changes blocks by itself: grass under the stone turns to dirt at y = -61 (index 3 of section -4).  When that position joined one of
        # vanilla's sets, the packet carries one entry more: such a pair is compared without the y = -61 entries (same entries, same order)
        def strip(h):
            return [e for e in entries(h) if not (section_pos(h)[1] == -4 and e[1] & 15 == 3)]
        stripped_n = stripped_e = 0
        for h in list(set(vs) - set(os_)):
            x, y, z = section_pos(h)
            cand = [g for g in set(os_) - set(vs) if section_pos(g) == (x, y, z) and strip(g) == strip(h)]
            if cand and y == -4:
                vs.remove(h); os_.remove(cand[0]); stripped_n += 1; stripped_e += len(strip(h)); notes.append(f"section {(x, y, z)}: random-tick grass to dirt at y = -61 in vanilla's set, rest identical ({len(strip(h))} entries)")
        vb = sorted(h for h in pick(sv, "minecraft:block_update") if block_pos(h)[1] != -61)      # y = -61: grass decaying under the stone (random tick)
        ob = sorted(h for h in pick(so, "minecraft:block_update") if block_pos(h)[1] != -61)
        if sorted(vs) != sorted(os_):
            msgs.append(f"section_blocks_update differ: vanilla {len(vs)} packets, dbcraft {len(os_)}; only vanilla {len(set(vs) - set(os_))}, only dbcraft {len(set(os_) - set(vs))}")
        # the order of sections inside one chunk (vanilla: ascending section index)
        for who, lst in (("vanilla", vs), ("dbcraft", os_)):
            last = {}
            for h in lst:
                x, y, z = section_pos(h)
                if (x, z) in last and y < last[(x, z)]:
                    msgs.append(f"{who}: sections of chunk {(x, z)} not in ascending order")
                last[(x, z)] = y
        if vb != ob:
            msgs.append(f"block_update differ: vanilla {len(vb)}, dbcraft {len(ob)}")
        tot["sbu"] += len(vs) + stripped_n; tot["bu"] += len(vb); tot["entries"] += sum(len(entries(h)) for h in vs) + stripped_e
        extra = sorted({p["name"].replace("minecraft:", "") for p in sv["packets"]} - {"section_blocks_update", "block_update"})
        status = "ok  " if not msgs else "FAIL"
        print(f"{status} {sv['label']}: {len(vs) + stripped_n} section_blocks_update ({sum(len(entries(h)) for h in vs) + stripped_e} entries), {len(vb)} block_update" +
              (f"   [vanilla also sent: {', '.join(extra)}]" if extra else ""))
        for m in notes:
            print("       note: " + m)
        for m in msgs:
            print("       " + m); bad += 1
            for h in sorted(set(vs) ^ set(os_))[:3]:
                print("       ", section_pos(h), entries(h)[:8])
    print(f"{len(van)} steps, {tot['sbu']} section_blocks_update packets ({tot['entries']} entries) and {tot['bu']} block_update packets compared; {'ALL IDENTICAL' if not bad else str(bad) + ' DIFFERENCES'}")
    sys.exit(1 if bad else 0)


main()
