#!/usr/bin/env python3
"""Chat and command rate limits (ServerGamePacketListenerImpl.detectRateSpam): a player who is not an operator is disconnected with `disconnect.spam` when its counter reaches
20 x the threshold (default 10 seconds: 200); every message adds 20 and the counter loses 1 per tick.  A scripted client "Spam" (not an operator) sends messages in patterns;
what is recorded is how many were answered before the disconnect, and the disconnect packet.  Run it against the REAL vanilla server and against dbcraft; `compare` requires equal.

usage: tests/e2e/spam_probe.py record --port P --out FILE        (vanilla: a fresh server, nobody an operator;  dbcraft: a dev gateway)
       tests/e2e/spam_probe.py compare VANILLA.json OURS.json
Patterns:  burst-chat N      N chat messages back to back (one tick)
           steady-chat MS N  N chat messages MS milliseconds apart
           burst-cmd N       N commands (/list) back to back
           steady-cmd MS N   N commands MS milliseconds apart
Each pattern uses a fresh connection (the server forgets the counters of a player who left).
"""
import json, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

PATTERNS = [("burst-chat", 9), ("burst-chat", 10), ("burst-chat", 11), ("burst-chat", 20), ("steady-chat", 500, 30), ("steady-chat", 200, 30),
            ("burst-cmd", 9), ("burst-cmd", 10), ("burst-cmd", 11), ("steady-cmd", 500, 30)]

def chat(text):
    return m.string(text) + struct.pack(">q", int(time.time() * 1000)) + struct.pack(">q", 0) + b"\x00" + m.varint(0) + b"\x00\x00\x00" + b"\x00"

def run(port, pat, host="127.0.0.1"):
    c = m.Client(host, port, "Spam"); c.settle(0.8, 15.0)
    k = len(c.events)
    kind = pat[0]
    msgs = pat[1] if kind.startswith("burst") else pat[2]
    gap = 0.0 if kind.startswith("burst") else pat[1] / 1000.0
    sent = 0
    for i in range(msgs):
        if not c.alive: break
        if kind.endswith("chat"): c.send("minecraft:chat", chat("hello %d" % i))
        else: c.send("minecraft:chat_command", m.string("list"))
        sent += 1
        if gap: time.sleep(gap); c.send("minecraft:client_tick_end")
    c.settle(0.6, 4.0)
    ev = c.events[k:]
    answered = sum(1 for e in ev if e["state"] != "mark" and e["dir"] == "clientbound" and e["name"] in ("minecraft:player_chat", "minecraft:system_chat") and (kind.endswith("chat") == (e["name"] == "minecraft:player_chat")))
    disc = [e["body"].hex() for e in ev if e["state"] != "mark" and e["dir"] == "clientbound" and e["name"] == "minecraft:disconnect"]
    c.close()
    time.sleep(0.5)
    return {"pattern": list(pat), "answered": answered, "disconnect": disc}

if sys.argv[1] == "record":
    port = int(sys.argv[sys.argv.index("--port") + 1]); out = sys.argv[sys.argv.index("--out") + 1]
    res = []
    for p in PATTERNS:
        r = run(port, p); res.append(r); print(r["pattern"], "answered", r["answered"], "disconnect", bool(r["disconnect"]), flush=True)
    json.dump(res, open(out, "w"), indent=1)
else:
    a, b = json.load(open(sys.argv[2])), json.load(open(sys.argv[3])); bad = 0
    for x, y in zip(a, b):
        ok = x == y; bad += not ok
        print("  %-9s %-22s vanilla answered %2d disconnect %-5s | dbcraft answered %2d disconnect %-5s" % ("same" if ok else "DIFFERENT", x["pattern"], x["answered"], bool(x["disconnect"]), y["answered"], bool(y["disconnect"])))
    print("%d of %d patterns identical" % (len(a) - bad, len(a)))
    sys.exit(1 if bad else 0)
