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

def packet(client, mark, name, nth=0, after=None):
    """nth packet called `name` after the mark `mark` (in client's capture), as frame hex"""
    ev = load(client)
    start = next(k for k, e in enumerate(ev) if e["name"] == mark)
    hits = [e for e in ev[start:] if e["name"] == "minecraft:" + name]
    return hits[nth]["hex"]

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

if __name__ == "__main__":
    if load("Op") is None:
        print("SKIP: no captures in", CAP, "(run tools/game_probe.py social against a vanilla server)"); sys.exit(0)
    fails = 0; n = 0
    for label, expr, ref in cases():
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
