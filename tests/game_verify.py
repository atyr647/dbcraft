#!/usr/bin/env python3
"""Compare SQL packet builders with packets captured from the REAL 26.3 server.

usage: [DBCRAFT_TESTDB=dbcraft_game] tests/game_verify.py [filter]
Needs: the test database (tests/sql/run.sh builds it), and captures made by tools/game_probe.py (default /tmp/game-scratch/cap, override
with DBCRAFT_CAPDIR).  Without captures it exits 0 and says it skipped.  Each case: a label, a SQL expression returning bytea (the whole frame,
including the length prefix), and which captured packet it must equal.  Nothing from the captures is stored in the repository.
"""
import json, os, subprocess, sys

CAP = os.environ.get("DBCRAFT_CAPDIR", "/tmp/game-scratch/cap")
DB = os.environ.get("DBCRAFT_TESTDB", "dbcraft_game")
PORT = os.environ.get("DBCRAFT_PGPORT", "54329")
want = sys.argv[1] if len(sys.argv) > 1 else ""

def load(client):
    p = os.path.join(CAP, f"social_{client}.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else None

def packet(client, mark, name, nth=0, contains=None):
    """nth packet called `name` after the mark `mark` (in client's capture), as frame hex; `contains` keeps only frames whose hex contains it"""
    ev = load(client)
    start = next(k for k, e in enumerate(ev) if e["name"] == mark)
    hits = [e for e in ev[start:] if e["name"] == "minecraft:" + name and (contains is None or contains in e["hex"])]
    return hits[nth]["hex"]

def body(frame_hex):
    """packet body bytes after the frame length and packet id"""
    b = bytes.fromhex(frame_hex); o = 0
    while b[o] & 0x80: o += 1
    o += 1
    while b[o] & 0x80: o += 1
    return b[o + 1:]

def varint(b, o=0):
    v = sh = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << sh
        if not c & 0x80: return v, o
        sh += 7

def sql(expr):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", PORT, "-U", "postgres", "-d", DB, "-v", "ON_ERROR_STOP=1", "-c",
                        f"select encode(({expr}), 'hex')"], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()

BOB = "faa5dca3-c3d4-354b-ae1b-dde9e5a14b3b"
OP = "83450b92-796c-35b3-8382-f4e4e7dac4dd"
PBOB = f"mc.tc_player('{BOB}'::uuid, 'Bob')"

def cases():
    # (label, SQL expression -> frame bytea, (client, mark, packet name, nth))
    yield ("system_chat: weather clear feedback", "mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('commands.weather.set.clear')))", ("Op", "cmd weather clear", "system_chat", 0))
    yield ("system_chat: time set feedback (list<string> args)", "mc.pkt_system_chat(proto.nbt_root(mc.tc_translate_strs('commands.time.set.time_marker', array['minecraft:overworld','minecraft:day'])))", ("Op", "cmd time set day", "system_chat", 0))
    yield ("system_chat: Bob joined the game", f"mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.joined', array[{PBOB}], 'yellow')))", ("Op", "bob joins", "system_chat", 0))
    yield ("system_chat: Bob left the game", f"mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.left', array[{PBOB}], 'yellow')))", ("Op", "bob leaves", "system_chat", 0))
    yield ("system_chat: gamemode survival feedback", f"mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('commands.gamemode.success.other', array[{PBOB}, mc.tc_translate('gameMode.survival')])))", ("Op", "cmd gamemode survival Bob", "system_chat", 0))
    yield ("system_chat: gamemode creative feedback", f"mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('commands.gamemode.success.other', array[{PBOB}, mc.tc_translate('gameMode.creative')])))", ("Op", "cmd gamemode creative Bob", "system_chat", 0))

def cases2():
    import struct
    BOBH = "faa5dca3c3d4354bae1bdde9e5a14b3b"
    add = body(packet("Op", "bob joins", "add_entity", 0, contains=BOBH)); eid, o = varint(add); o += 16; o = varint(add, o)[1]
    x, y, z = struct.unpack(">ddd", add[o:o + 24])
    yield ("player_info_update: Bob joins (all actions)", f"mc.pkt_player_info_add(array[mc.pie_add('{BOB}'::uuid, 'Bob', 1)])", ("Op", "bob joins", "player_info_update", 0, BOBH))
    yield ("player_info_update: game mode survival", f"mc.pkt_player_info_gamemode('{BOB}'::uuid, 0)", ("Op", "cmd gamemode survival Bob", "player_info_update", 0))
    yield ("player_info_update: game mode creative", f"mc.pkt_player_info_gamemode('{BOB}'::uuid, 1)", ("Op", "cmd gamemode creative Bob", "player_info_update", 0))
    yield ("player_info_remove: Bob leaves", f"mc.pkt_player_info_remove(array['{BOB}'::uuid])", ("Op", "bob leaves", "player_info_remove", 0))
    yield ("add_entity: Bob as a player entity", f"mc.pkt_add_player_entity({eid}, '{BOB}'::uuid, {x!r}, {y!r}, {z!r}, 0, 0, 0)", ("Op", "bob joins", "add_entity", 0, BOBH))
    hx = proto_varint_hex(eid)
    yield ("move_entity_pos: +1.0 block in x, 2 ticks", f"mc.pkt_move_entity_pos({eid}, 4096, 0, 0, 2, true)", ("Op", "bob moves", "move_entity_pos", 0, hx + "0302"))
    yield ("move_entity_pos_rot: +0.5/+0.5, yaw 90 pitch 10", f"mc.pkt_move_entity_pos_rot({eid}, 2048, 0, 2048, 2, 90, 10, true)", ("Op", "bob moves", "move_entity_pos_rot", 0, hx + "0302"))
    yield ("move_entity_rot: yaw 180 pitch -20 (floor rounding)", f"mc.pkt_move_entity_rot({eid}, 180, -20, true)", ("Op", "bob moves", "move_entity_rot", 0, hx))
    yield ("rotate_head: 90", f"mc.pkt_rotate_head({eid}, 90)", ("Op", "bob moves", "rotate_head", 0, hx + "40"))
    yield ("rotate_head: 180", f"mc.pkt_rotate_head({eid}, 180)", ("Op", "bob moves", "rotate_head", 0, hx + "80"))
    pp = body(packet("Bob", "bob moves", "player_position", 0)); tid, o = varint(pp)
    x, y, z = struct.unpack(">ddd", pp[o:o + 24]); yaw, pitch = struct.unpack(">ff", pp[o + 48:o + 56])
    yield ("player_position: correction after an illegal 40-block jump", f"mc.pkt_player_position({tid}, {x!r}, {y!r}, {z!r}, 0, 0, 0, {yaw!r}, {pitch!r}, 0)", ("Bob", "bob moves", "player_position", 0))
    pc = body(packet("Op", "bob chats", "player_chat", 0)); msg = b"hello world"; i = pc.index(msg) + len(msg)
    ts, salt = struct.unpack(">qq", pc[i:i + 16])
    yield ("player_chat: Bob says hello world", f"mc.pkt_player_chat(0, '{BOB}'::uuid, 0, 'hello world', {ts}, {salt}, 0, mc.tc_player('{BOB}'::uuid, 'Bob'))", ("Op", "bob chats", "player_chat", 0))

def cases3():
    """set_time: the periodic form (game time, no clocks) and the one-clock form sent after /time set"""
    import struct
    ev = load("Op")
    start = next(k for k, e in enumerate(ev) if e["name"] == "cmd list")
    periodic = next(e for e in ev[start:] if e["name"] == "minecraft:set_time" and len(e["hex"]) // 2 == 11)
    gt = struct.unpack(">q", body(periodic["hex"])[:8])[0]
    yield ("set_time: periodic game time, empty clock list", f"mc.pkt_set_time({gt})", ("Op", "cmd list", "set_time", 0, "0a73"))
    start = next(k for k, e in enumerate(ev) if e["name"] == "cmd time set day")
    clocked = next(e for e in ev[start:] if e["name"] == "minecraft:set_time" and len(e["hex"]) // 2 > 11)
    b = body(clocked["hex"]); gt = struct.unpack(">q", b[:8])[0]; n, o = varint(b, 8); cid, o = varint(b, o); ticks, o = varint(b, o)
    yield ("set_time: one clock entry after /time set", f"mc.pkt_set_time({gt}, array[{cid}], array[{ticks}::bigint])", ("Op", "cmd time set day", "set_time", 0))

def proto_varint_hex(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); return out.hex()

if __name__ == "__main__":
    if load("Op") is None:
        print("SKIP: no captures in", CAP, "(run tools/game_probe.py social against a vanilla server)"); sys.exit(0)
    fails = 0; n = 0
    for label, expr, ref in list(cases()) + list(cases2()) + list(cases3()):
        if want not in label: continue
        n += 1
        try:
            got = sql(expr); exp = packet(*ref)
        except Exception as e:
            print(f"ERROR {label}: {e}"); fails += 1; continue
        if got == exp: print(f"ok    {label}  ({len(exp) // 2} bytes identical)")
        else:
            fails += 1; print(f"FAIL  {label}\n   got {got[:200]}\n   exp {exp[:200]}")
    print(f"{n - fails}/{n} match the real server"); sys.exit(1 if fails else 0)
