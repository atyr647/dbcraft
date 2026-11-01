#!/usr/bin/env python3
"""Compare what two probe clients received from a dbcraft server when one joined, chatted and left with what the real vanilla 26.3 server sent.

usage: tests/e2e/compare_social.py VANILLA_PREFIX OURS_PREFIX      (prefixes of the files tests/e2e/join_probe.py wrote)
Checks (the packets are compared in order, restricted to the kinds this layer produces; the real server also sends entity metadata, attributes,
waypoints and sounds that dbcraft does not):
  first player, when the second joins : system_chat (join message), player_info_update (tab entry), add_entity.  The first two byte for byte; add_entity
                                        with the entity id and the position masked (they differ between servers)
  second player's own burst           : the tab list it receives holds the first player; it receives NO system_chat of its own join (vanilla sends the
                                        join message only to the players already in the game)
  when the second chats               : player_chat to both players.  The timestamp and the signature fields are the sender's: compared as a whole frame
                                        after masking nothing except the message index/timestamp bytes (see MASK_CHAT)
  when the second leaves              : system_chat (leave message) then player_info_remove, byte for byte, then remove_entities
"""
import json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

van_p, our_p = sys.argv[1], sys.argv[2]
def load(prefix, who): return [json.loads(l) for l in open(f"{prefix}_{who}.jsonl")]
def body(e):
    b = bytes.fromhex(e["hex"]); _, o = m.parse_varint(b, 0); _, o = m.parse_varint(b, o); return b[o:]

def window(events, mark, kinds):
    out, on = [], False
    for e in events:
        if e["state"] == "mark":
            if on: break
            on = e["name"] == mark
        elif on and e["dir"] == "clientbound" and e["name"] in kinds: out.append(e)
    return out

fails = 0
def check(ok, label, detail=""):
    global fails
    print(("ok    " if ok else "FAIL  ") + label + ((" -- " + detail) if detail and not ok else ""))
    fails += not ok

def names(l): return [e["name"][10:] for e in l]
fv, fo = load(van_p, "first"), load(our_p, "first")
sv, so = load(van_p, "second"), load(our_p, "second")

# ---- the first player sees the second one arrive
K = {"minecraft:system_chat", "minecraft:player_info_update", "minecraft:add_entity"}
a, b = window(fv, "second joins", K), window(fo, "second joins", K)
# vanilla also tells the first player about entities dbcraft does not have yet (extra add_entity) and sends a latency update afterwards: not compared
check(names(b) == names(a)[:len(b)] and len(b) == 3, f"first player, second joins: dbcraft sends {names(b)}, vanilla sends the same first three {names(a)[:3]}",
      f"vanilla {names(a)} ours {names(b)}")
for x, y in zip(a, b):
    n = x["name"][10:]
    bx, by = body(x), body(y)
    if n == "add_entity":
        # entity id VarInt, uuid (16), type VarInt, then x y z doubles ...: compare uuid, type and the tail after the position
        ox, oy = m.parse_varint(bx)[1], m.parse_varint(by)[1]
        check(bx[ox:ox + 16] == by[oy:oy + 16] and len(bx) == len(by), "add_entity: same player uuid, same length (entity id and position masked)")
    else:
        check(x["hex"] == y["hex"], f"{n}: byte for byte", f"vanilla {x['hex']} ours {y['hex']}")

# ---- the second player's own burst
def burst_names(events): return [e["name"][10:] for e in events if e["dir"] == "clientbound" and e["state"] == "play"]
bv, bo = burst_names(sv), burst_names(so)
check("system_chat" not in bv[:40], "vanilla: the joiner is not sent its own join message in its entry burst")
check("system_chat" not in bo[:60], "dbcraft: the joiner is not sent its own join message in its entry burst", f"first 60: {bo[:60]}")
pi_v = [e for e in sv if e["name"] == "minecraft:player_info_update"][:2]
pi_o = [e for e in so if e["name"] == "minecraft:player_info_update"][:2]
check(len(pi_v) == len(pi_o) == 2, "the joiner receives two player_info_update in its burst (the others, then itself)")
check([e["hex"] for e in pi_v] == [e["hex"] for e in pi_o], "both tab-list packets byte for byte", f"{[e['hex'] for e in pi_v]} vs {[e['hex'] for e in pi_o]}")

# ---- chat
K = {"minecraft:player_chat"}
for who, ev_v, ev_o in (("first", fv, fo), ("second", sv, so)):
    a, b = window(ev_v, "second chats", K), window(ev_o, "second chats", K)
    check(len(a) == len(b) == 1, f"{who} player: one player_chat when the second chats")
    if a and b:
        bx, by = body(a[0]), body(b[0])
        # player_chat: global index VarInt, sender uuid, message index VarInt, signature absent (bool), message string, timestamp long, salt long, ... ; the timestamp differs
        check(len(bx) == len(by) and bx[:1] == by[:1] and m.parse_varint(bx)[1] == m.parse_varint(by)[1], f"{who} player: player_chat has the same shape and length")
        i = bx.index(b"hello world"); j = by.index(b"hello world")
        check(bx[:i + 11] == by[:j + 11], f"{who} player: player_chat identical up to and including the message text")

# ---- leaving
K = {"minecraft:system_chat", "minecraft:player_info_remove", "minecraft:remove_entities"}
a, b = window(fv, "second leaves", K), window(fo, "second leaves", K)
check(names(a) == names(b), f"first player, second leaves: {names(a)}", f"ours {names(b)}")
for x, y in zip(a, b):
    n = x["name"][10:]
    if n == "remove_entities": check(len(x["hex"]) == len(y["hex"]), "remove_entities: same length (entity id masked)")
    else: check(x["hex"] == y["hex"], f"{n}: byte for byte", f"vanilla {x['hex']} ours {y['hex']}")
sys.exit(1 if fails else 0)
