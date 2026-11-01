#!/usr/bin/env python3
"""Compare the block-change packets a dbcraft server sent two probe clients with what the real vanilla 26.3 server sent the same probe.

usage: tests/e2e/compare_block.py VANILLA_PREFIX OURS_PREFIX        (prefixes of the files tests/e2e/block_probe.py wrote: <prefix>_actor.jsonl,
                                                                      <prefix>_observer.jsonl, <prefix>_meta.json)
Positions are made relative to the block under the actor's feet (they differ between servers: vanilla spreads spawns at random).  Only packets about the
blocks the probe touched are compared (block_update, level_event, block_changed_ack); the real server also sends sounds, swing animations, random-tick
changes elsewhere (grass turning to dirt), which are not the subject.  Step 5 (place, then start+stop destroy in one go) is compared by its final
state only: how many acks vanilla sends there depends on tick timing.
"""
import json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

van_p, our_p = sys.argv[1], sys.argv[2]
def load(prefix, who): return [json.loads(l) for l in open(f"{prefix}_{who}.jsonl")]
def meta(prefix): return json.load(open(prefix + "_meta.json"))

def body(e):
    b = bytes.fromhex(e["hex"]); _, o = m.parse_varint(b, 0); _, o = m.parse_varint(b, o); return b[o:]

def steps(events):
    """{step label: [clientbound events after its mark and before the next mark]}"""
    out, cur = {}, None
    for e in events:
        if e["state"] == "mark": cur = e["name"]; out[cur] = []
        elif cur is not None and e["dir"] == "clientbound": out[cur].append(e)
    return out

def describe(e, base, touched):
    """a comparable tuple for a relevant packet, or None"""
    n, b = e["name"][10:], body(e)
    if n == "block_update":
        x, y, z = m.unposition(b, 0); rel = (x - base[0], y - base[1], z - base[2])
        return ("block_update", rel, m.parse_varint(b, 8)[0]) if rel in touched else None
    if n == "level_event":
        ev = struct.unpack(">i", b[:4])[0]; x, y, z = m.unposition(b, 4); rel = (x - base[0], y - base[1], z - base[2])
        return ("level_event", ev, rel, struct.unpack(">i", b[12:16])[0]) if rel in touched else None
    if n == "block_changed_ack":
        return ("ack", m.parse_varint(b, 0)[0])
    return None

touched = {(0, 0, 0), (1, 0, 0), (1, 1, 0)}      # the block under the feet, its neighbour (clicked), the block above that (placed)
mv, mo = meta(van_p), meta(our_p)
fails = 0
for who in ("actor", "observer"):
    sv, so = steps(load(van_p, who)), steps(load(our_p, who))
    for label in sv:
        if label.startswith("place again"):          # step 5: final state only
            continue
        a = [d for d in (describe(e, mv["base"], touched) for e in sv[label]) if d]
        b = [d for d in (describe(e, mo["base"], touched) for e in so.get(label, [])) if d]
        if who == "observer": a = [d for d in a if d[0] != "ack"]; b = [d for d in b if d[0] != "ack"]
        else:                                          # acks: vanilla sends one per tick for the latest sequence; compare the last one only
            def last_ack(l): return [d for d in l if d[0] != "ack"] + [d for d in l if d[0] == "ack"][-1:]
            a, b = last_ack(a), last_ack(b)
        ok = a == b
        fails += not ok
        print(("ok    " if ok else "FAIL  ") + f"{who:8s} {label}: " + (", ".join(f"{d[0]}{d[1:]}" for d in a) or "nothing"))
        if not ok: print(f"      ours: {b}")
sys.exit(1 if fails else 0)
