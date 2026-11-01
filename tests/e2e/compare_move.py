#!/usr/bin/env python3
"""Compare the chunk streaming a dbcraft server did while a probe client walked east with what the real vanilla 26.3 server did for the same probe.

usage: tests/e2e/compare_move.py VANILLA.jsonl OURS.jsonl      (files made by tests/e2e/move_probe.py)
Each time the client's chunk changes, the server sends set_chunk_cache_center, forget_level_chunk for every chunk that left the square, then the chunks
that entered it, nearest first (vanilla splits those into several chunk batches, dbcraft sends one; and vanilla orders equally distant chunks differently from
one crossing to the next: what is compared is the set and that both are sorted by distance).  Coordinates are made relative to the centre so that two servers with different spawn points can be compared:
  centre step (dx, dz) from the previous centre, forgets relative to the previous centre, chunks relative to the new centre.
"""
import json, struct, sys

def load(path): return [json.loads(l) for l in open(path)]
def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 127) << s
        if c < 128: return v, o
        s += 7
def body(e):
    b = bytes.fromhex(e["hex"]); _, o = vi(b, 0); _, o = vi(b, o); return b[o:]

def groups(events):
    center = None; out = []; cur = None
    for e in events:
        if e["dir"] != "clientbound" or e["state"] != "play": continue
        n = e["name"][10:]
        if n == "set_chunk_cache_center":
            x, o = vi(body(e), 0); z, _ = vi(body(e), o)
            x, z = (x - (1 << 32) if x >= 1 << 31 else x), (z - (1 << 32) if z >= 1 << 31 else z)      # VarInt of a negative int: 5 bytes, unsigned
            if center is None: center = (x, z); continue            # the one in the entry burst
            cur = {"step": (x - center[0], z - center[1]), "forgets": [], "chunks": []}; out.append(cur)
            prev = center; center = (x, z); cur["prev"] = prev; cur["center"] = center
        elif cur is not None and n == "forget_level_chunk":
            z, x = struct.unpack(">ii", body(e)[:8]); cur["forgets"].append((x - cur["prev"][0], z - cur["prev"][1]))
        elif cur is not None and n == "level_chunk_with_light":
            x, z = struct.unpack(">ii", body(e)[:8]); cur["chunks"].append((x - cur["center"][0], z - cur["center"][1]))
    return out

gv, go = groups(load(sys.argv[1])), groups(load(sys.argv[2]))
fails = 0
def check(ok, label, detail=""):
    global fails
    print(("ok    " if ok else "FAIL  ") + label + ((" -- " + detail) if detail and not ok else ""))
    fails += not ok
n = min(len(gv), len(go))
check(n >= 2 and len(gv) == len(go), f"chunk streaming happened the same number of times ({len(gv)} vanilla, {len(go)} ours)")
for i in range(n):
    a, b = gv[i], go[i]
    check(a["step"] == b["step"], f"crossing {i + 1}: the centre moved by {a['step']}", f"ours {b['step']}")
    check(a["forgets"] == b["forgets"], f"crossing {i + 1}: {len(a['forgets'])} forget_level_chunk, same chunks in the same order", f"vanilla {a['forgets']} ours {b['forgets']}")
    dist = lambda l: [x * x + z * z for x, z in l]
    check(sorted(a["chunks"]) == sorted(b["chunks"]) and dist(b["chunks"]) == sorted(dist(b["chunks"])) and dist(a["chunks"]) == sorted(dist(a["chunks"])),
          f"crossing {i + 1}: {len(a['chunks'])} new chunks, the same set, both nearest first (vanilla breaks ties between equally distant chunks differently each time)",
          f"vanilla {a['chunks']} ours {b['chunks']}")
sys.exit(1 if fails else 0)
