#!/usr/bin/env python3
"""Replay the scenario recorded from the REAL 26.3 server (tools/game_probe.py social / kick) against the SQL game logic, then compare, frame by
frame, what each player received.  Each case runs in a transaction that is rolled back.

usage: [DBCRAFT_TESTDB=dbcraft_game] tests/game_replay.py [filter]
Packets are split into frames and compared by name, in order, restricted to the packet kinds the case is about (a real server also sends
entity metadata, attributes, waypoints, sounds ... that this module does not produce; those are listed in docs/GAME.md as not implemented).
"""
import json, os, struct, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from game_verify import CAP, DB, PORT, BOB, OP, load, body, varint

want = sys.argv[1] if len(sys.argv) > 1 else ""
reports = os.environ.get("DBCRAFT_REPORTS", "/home/user/atyr647/adacraft/generated/26.3/reports")
pk = json.load(open(os.path.join(reports, "packets.json")))["play"]["clientbound"]
NAME = {e["protocol_id"]: n.replace("minecraft:", "") for n, e in pk.items()}

def split_frames(stream):
    """concatenated frames -> [(name, hex)]"""
    out, o = [], 0
    while o < len(stream):
        ln, p = varint(stream, o); pid, q = varint(stream, p)
        out.append((NAME.get(pid, f"id{pid}"), stream[o:p + ln].hex())); o = p + ln
    return out

def window(client, mark, scen="social"):
    """frames the real server sent `client` after the mark and before the next mark"""
    path = os.path.join(CAP, f"{scen}_{client}.jsonl")
    ev = [json.loads(l) for l in open(path)]
    start = next(k for k, e in enumerate(ev) if e["name"] == mark) if mark else -1
    end = next((k for k, e in enumerate(ev) if k > start and e["state"] == "mark"), len(ev))
    return [(e["name"].replace("minecraft:", ""), e["hex"]) for e in ev[start + 1:end] if e["state"] == "play"]

def psql(script):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", PORT, "-U", "postgres", "-d", DB, "-v", "ON_ERROR_STOP=1"], input=script, capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr.strip()[:600])
    return r.stdout.split("\n")

SETUP = f"""
truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick; delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
update mc.server_property set value = '10' where key = 'max-players'; update mc.server_property set value = 'false' where key = 'white-list';
update mc.server_property set value = 'peaceful' where key = 'difficulty'; update mc.server_property set value = 'creative' where key = 'gamemode';
update mc.game_state set raining = false, thundering = false, game_time = 0, day_time = 0;
insert into mc.op values ('{OP}', 'Op', 4, false);
perform mc.on_join(1, '{OP}', 'Op'); perform mc.on_join(2, '{BOB}', 'Bob'); perform mc.refresh_visibility();
"""

def replay(extra, action, conns):
    """conns: {conn_id: (client, mark, keep-names set)}"""
    script = f"begin;\ndo $$ begin {SETUP} {extra} truncate mc.play_out; {action} end $$;\n"
    for c in conns: script += f"select coalesce(string_agg(encode(data, 'hex'), '' order by seq), '') from mc.play_out where conn_id = {c};\n"
    script += "rollback;\n"
    lines = psql(script)
    return dict(zip(conns, lines))

def caps():
    soc = load("Op")
    return soc

def case(label, extra, action, conns, scen="social"):
    """compare per connection: actual frames vs the recorded window, both filtered to the kinds in keep"""
    if want not in label: return None
    try:
        got = replay(extra, action, conns)
    except Exception as e:
        print(f"ERROR {label}: {e}"); return False
    ok = True; detail = []
    for c, (client, mark, keep) in conns.items():
        a = [f for f in split_frames(bytes.fromhex(got[c])) if f[0] in keep]
        e = [f for f in window(client, mark, scen) if f[0] in keep]
        if a != e:
            ok = False; detail.append(f"   conn {c} ({client}): expected {[n for n, _ in e]} got {[n for n, _ in a]}")
            for (an, ah), (en, eh) in zip(a, e):
                if ah != eh:
                    k = next((i for i, (p, q) in enumerate(zip(ah, eh)) if p != q), min(len(ah), len(eh))) // 2 * 2
                    detail.append(f"      {an}: first difference at byte {k // 2} (got {len(ah) // 2} bytes, expected {len(eh) // 2})\n        got ...{ah[max(0, k - 24):k + 56]}\n        exp ...{eh[max(0, k - 24):k + 56]}")
        else:
            detail.append(f"   {client}: {[n for n, _ in a]} ({sum(len(h) // 2 for _, h in a)} bytes identical)")
    print(("ok    " if ok else "FAIL  ") + label); [print(d) for d in detail if (not ok) or True]
    return ok

def main():
    if load("Op") is None:
        print("SKIP: no captures in", CAP); return 0
    add = body([e for e in load("Op") if e["name"] == "minecraft:add_entity"][0]["hex"]) if False else None
    results = []
    sc = lambda *a, **k: results.append(case(*a, **k))
    sc("/list", "", "perform mc.run_command(1, 'list');", {1: ("Op", "cmd list", {"system_chat"})})
    sc("/time set day: feedback", "", "perform mc.run_command(1, 'time set day');", {1: ("Op", "cmd time set day", {"system_chat"})})
    sc("/weather clear on a clear world: feedback and no events", "", "perform mc.run_command(1, 'weather clear');", {1: ("Op", "cmd weather clear", {"system_chat", "game_event"})})
    for mode, mark in (("survival", "cmd gamemode survival Bob"), ("creative", "cmd gamemode creative Bob")):
        sc(f"/gamemode {mode} Bob: what Op and Bob each receive", "", f"perform mc.run_command(1, 'gamemode {mode} Bob');",
           {1: ("Op", mark, {"system_chat", "player_info_update"}), 2: ("Bob", mark, {"system_chat", "player_info_update", "player_abilities", "game_event"})})
    sc("/say hi there: disguised_chat to everyone", "", "perform mc.run_command(1, 'say hi there');",
       {1: ("Op", "cmd say hi there", {"disguised_chat"}), 2: ("Bob", "cmd say hi there", {"disguised_chat"})})
    sc("/tp Bob 10 -60 10: feedback and the player_position Bob receives", "update mc.player set teleport_id = 2 where name = 'Bob';", "perform mc.run_command(1, 'tp Bob 10 -60 10');",
       {1: ("Op", "cmd tp Bob 10 -60 10", {"system_chat"}), 2: ("Bob", "cmd tp Bob 10 -60 10", {"player_position"})})
    sc("/give Bob stone 3 (merges into the creative-set stack of 5): feedback and container_set_slot", f"perform mc.set_slot('{BOB}', 36, 'minecraft:stone', 5);",
       "perform mc.run_command(1, 'give Bob minecraft:stone 3');", {1: ("Op", "cmd give Bob minecraft:stone 3", {"system_chat"}), 2: ("Bob", "cmd give Bob minecraft:stone 3", {"container_set_slot"})})
    sc("/difficulty peaceful when already peaceful: failure message", "", "perform mc.run_command(1, 'difficulty peaceful');", {1: ("Op", "cmd difficulty peaceful", {"system_chat"})})
    sc("/op Bob", "", "perform mc.run_command(1, 'op Bob');", {1: ("Op", "cmd op Bob", {"system_chat"})})
    sc("/deop Bob", "", "perform mc.run_command(1, 'deop Bob');", {1: ("Op", "cmd deop Bob", {"system_chat"})})
    sc("/whitelist list (empty)", "", "perform mc.run_command(1, 'whitelist list');", {1: ("Op", "cmd whitelist list", {"system_chat"})})
    sc("unknown command", "", "perform mc.run_command(1, 'nosuchcommand');", {1: ("Op", "cmd nosuchcommand", {"system_chat"})})
    # chat: Bob types "hello world"; both players receive player_chat
    pc = body([e for e in load("Op") if e["name"] == "minecraft:player_chat"][0]["hex"]); msg = b"hello world"; i = pc.index(msg) + len(msg)
    ts = struct.unpack(">q", pc[i:i + 8])[0]
    sc("chat: Bob says hello world; both receive player_chat", "",
       f"insert into mc.play_in_work (conn_id, packet_id, body) values (2, mc.sid('chat'), proto.string('hello world') || proto.i64({ts}) || proto.i64(0) || '\\x00'::bytea || proto.varint(0) || '\\x000000'::bytea || '\\x00'::bytea); perform mc.apply_chat(1);",
       {1: ("Op", "bob chats", {"player_chat"}), 2: ("Bob", "bob chats", {"player_chat"})})
    # join: Op sees Bob arrive.  Spawn and entity id are set to the recorded ones so the add_entity frame can match.
    add = body([e for e in load("Op") if e["name"] == "minecraft:add_entity" and "faa5dca3c3d4354bae1bdde9e5a14b3b" in e["hex"]][0]["hex"])
    eid, o = varint(add); o += 16; o = varint(add, o)[1]; x, y, z = struct.unpack(">ddd", add[o:o + 24])
    sc("Bob joins: Op receives the join message, the tab list entry, then add_entity",
       f"perform mc.on_leave(2); delete from mc.player where name = 'Bob'; update mc.game_state set spawn_x = {x!r}, spawn_y = {y!r}, spawn_z = {z!r}; perform setval('mc.entity_id_seq', {eid - 1});",
       f"perform mc.on_join(2, '{BOB}', 'Bob'); perform mc.refresh_visibility();", {1: ("Op", "bob joins", {"system_chat", "player_info_update", "add_entity"})})
    sc("Bob leaves: Op receives the leave message and the tab list removal", "", "perform mc.on_leave(2);", {1: ("Op", "bob leaves", {"system_chat", "player_info_remove"})})
    sc("invalid movement kick: the disconnect packet", "", "perform mc.kick(1, 'multiplayer.disconnect.invalid_player_movement');", {1: ("K", "", {"disconnect"})}, scen="kick") if os.path.exists(os.path.join(CAP, "kick_K.jsonl")) else None
    ok = [r for r in results if r is not None]
    print(f"{sum(ok)}/{len(ok)} replayed cases match the real server"); return 0 if all(ok) else 1

if __name__ == "__main__":
    sys.exit(main())
