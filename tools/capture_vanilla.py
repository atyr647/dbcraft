#!/usr/bin/env python3
"""Connect to a vanilla 26.3 server (offline mode) as a minimal client and record every packet, byte for byte.

usage: tools/capture_vanilla.py [--host 127.0.0.1] [--port 25599] [--name Probe] [--seconds 6] [--out tests/fixtures/captured/play.jsonl]
        [--compression N]   (must match the server's network-compression-threshold; -1 = off)
Output: one JSON object per packet: {t, dir, state, id, name, len, hex}.  Captures contain Mojang data (registries etc.), so they are gitignored.
Packet ids come from the generator's packets.json (DBCRAFT_REPORTS or the adacraft checkout).  Standard library only.
"""
import argparse, hashlib, json, os, socket, struct, sys, time, zlib

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25599)
ap.add_argument("--name", default="Probe"); ap.add_argument("--seconds", type=float, default=6.0)
ap.add_argument("--compression", type=int, default=-1)
ap.add_argument("--out", default="tests/fixtures/captured/play.jsonl")
ap.add_argument("--no-teleport-ack", action="store_true")
ap.add_argument("--status", action="store_true", help="capture a status ping instead of a login")
a = ap.parse_args()

reports = os.environ.get("DBCRAFT_REPORTS", "/home/user/atyr647/adacraft/generated/26.3/reports")
packets = json.load(open(os.path.join(reports, "packets.json")))
ID, NAME = {}, {}
for st, dirs in packets.items():
    for d, ps in dirs.items():
        for n, e in ps.items():
            ID[(st, d, n)] = e["protocol_id"]; NAME[(st, d, e["protocol_id"])] = n

def varint(n):
    n &= 0xFFFFFFFF; out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); return bytes(out)
def string(s): b = s.encode(); return varint(len(b)) + b
def read_varint_sock(sock):
    v = shift = 0
    while True:
        b = sock.recv(1)
        if not b: raise EOFError
        v |= (b[0] & 0x7F) << shift
        if not b[0] & 0x80: return v
        shift += 7
def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c: raise EOFError
        buf += c
    return bytes(buf)
def parse_varint(b, o=0):
    v = shift = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << shift
        if not c & 0x80: return v, o
        shift += 7

s = socket.create_connection((a.host, a.port)); s.settimeout(5)
os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
out = open(a.out, "w"); t0 = time.time(); state = "handshake"; threshold = a.compression
def record(direction, raw_payload, wire):
    pid, o = parse_varint(raw_payload)
    out.write(json.dumps({"t": round(time.time() - t0, 4), "dir": direction, "state": state, "id": pid,
                          "name": NAME.get((state, direction, pid), "?"), "len": len(wire), "hex": wire.hex()}) + "\n")
    return pid, raw_payload[o:]
def send(name, body=b""):
    pid = ID[(state, "serverbound", name)]; payload = varint(pid) + body
    if threshold >= 0: wire = varint(len(payload) + 1) + b"\x00" + payload
    else: wire = varint(len(payload)) + payload
    s.sendall(wire); record("serverbound", payload, wire)
def recv():
    ln = read_varint_sock(s); raw = read_exact(s, ln); wire = varint(ln) + raw
    if threshold >= 0:
        dl, o = parse_varint(raw); payload = raw[o:] if dl == 0 else zlib.decompress(raw[o:])
    else: payload = raw
    pid, body = record("clientbound", payload, wire)
    return NAME.get((state, "clientbound", pid), "?"), body

# --- handshake
intent = 1 if a.status else 2
payload = varint(0) + varint(777) + string(a.host) + struct.pack(">H", a.port) + varint(intent)
s.sendall(varint(len(payload)) + payload); record("serverbound", payload, varint(len(payload)) + payload)
if a.status:
    state = "status"; send("minecraft:status_request"); print(recv()[0])
    send("minecraft:ping_request", struct.pack(">q", 123456789)); print(recv()[0]); sys.exit(0)

# --- login (offline mode: UUID v3 of "OfflinePlayer:<name>")
state = "login"
h = bytearray(hashlib.md5(("OfflinePlayer:" + a.name).encode()).digest()); h[6] = (h[6] & 0x0F) | 0x30; h[8] = (h[8] & 0x3F) | 0x80
send("minecraft:hello", string(a.name) + bytes(h))
while True:
    n, body = recv()
    if n == "minecraft:login_compression": threshold, _ = parse_varint(body)
    if n == "minecraft:login_finished": break
    if n == "minecraft:login_disconnect": sys.exit("login refused: " + body.decode(errors="replace"))
send("minecraft:login_acknowledged"); state = "configuration"

# --- configuration
while True:
    n, body = recv()
    if n == "minecraft:select_known_packs": send("minecraft:select_known_packs", varint(0))   # we know no packs: server sends everything
    elif n == "minecraft:keep_alive": send("minecraft:keep_alive", body)
    elif n == "minecraft:ping": send("minecraft:pong", body)
    elif n == "minecraft:disconnect": sys.exit("disconnected in configuration")
    elif n == "minecraft:finish_configuration": break
send("minecraft:finish_configuration"); state = "play"

# --- play
end = time.time() + a.seconds; loaded_sent = False
while time.time() < end:
    try: n, body = recv()
    except socket.timeout: break
    if n == "minecraft:keep_alive": send("minecraft:keep_alive", body)
    elif n == "minecraft:ping": send("minecraft:pong", body)
    elif n == "minecraft:player_position":
        if not a.no_teleport_ack:
            # 26.3 layout (read from the class bytecode): accept_teleportation = id VarInt, x y z (doubles), yRot xRot (floats).
            # player_position = id VarInt, x y z, delta x y z (doubles), yRot xRot (floats), relative-flags int.
            tid, o = parse_varint(body); send("minecraft:accept_teleportation", body[:o] + body[o:o + 24] + body[o + 48:o + 56])
        if not loaded_sent: send("minecraft:player_loaded"); loaded_sent = True
    elif n == "minecraft:chunk_batch_finished": send("minecraft:chunk_batch_received", struct.pack(">f", 20.0))
    elif n == "minecraft:disconnect": print("disconnected in play"); break
out.close()
rows = [json.loads(l) for l in open(a.out)]
from collections import Counter
c = Counter((r["state"], r["dir"], r["name"]) for r in rows)
print(f"{len(rows)} packets, {sum(r['len'] for r in rows)} bytes -> {a.out}")
for (st, d, n), k in sorted(c.items(), key=lambda x: (["handshake","status","login","configuration","play"].index(x[0][0]), x[0][1])):
    print(f"  {st:13s} {d:11s} {n:45s} x{k}")
