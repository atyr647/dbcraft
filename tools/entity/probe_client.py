#!/usr/bin/env python3
"""A lean viewer for the entity comparisons: logs in (offline mode) to a vanilla or dbcraft server, answers keep-alive / teleport / chunk-batch like a client, discards everything else
but COUNTS it: packets and bytes per clientbound packet name, so the traffic a viewer receives can be compared between servers.  Stops after --seconds (or on SIGTERM) and writes
a JSON summary (--out).  Unlike tools/capture_vanilla.py it does not record packets (5,000 moving mobs would be megabytes per second).

usage: tools/entity/probe_client.py --port 25911 --name Stay --seconds 120 --out counts.json [--mark FILE]
  --mark FILE: while running, each second the cumulative counts are rewritten to FILE (atomically), so a driver can take differences over a window.
Standard library only.  Packet ids from the data generator reports ($DBCRAFT_REPORTS/packets.json).
"""
import argparse, hashlib, json, os, signal, socket, struct, sys, time, zlib

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25599)
ap.add_argument("--name", default="Stay"); ap.add_argument("--seconds", type=float, default=60.0)
ap.add_argument("--out", default=""); ap.add_argument("--mark", default="")
a = ap.parse_args()
reports = os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports"))
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


def parse_varint(b, o=0):
    v = shift = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << shift
        if not c & 0x80: return v, o
        shift += 7


class Conn:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port)); self.s.settimeout(30); self.buf = bytearray(); self.threshold = -1; self.state = "handshake"
        self.counts = {}      # name -> [packets, bytes]

    def send(self, name, body=b""):
        payload = varint(ID[(self.state, "serverbound", name)]) + body
        wire = (varint(len(payload) + 1) + b"\x00" + payload) if self.threshold >= 0 else varint(len(payload)) + payload
        self.s.sendall(wire)

    def frames(self):
        """yield (name, body, wire_len) for every complete frame; blocks for more data"""
        while True:
            while True:
                try:
                    ln, o = parse_varint(self.buf)
                except IndexError:
                    break
                if len(self.buf) < o + ln: break
                raw = bytes(self.buf[o:o + ln]); del self.buf[:o + ln]
                if self.threshold >= 0:
                    dl, o2 = parse_varint(raw); payload = raw[o2:] if dl == 0 else zlib.decompress(raw[o2:])
                else: payload = raw
                pid, o3 = parse_varint(payload)
                yield NAME.get((self.state, "clientbound", pid), "?"), payload[o3:], o + ln
            chunk = self.s.recv(1 << 20)
            if not chunk: raise EOFError
            self.buf += chunk


c = Conn(a.host, a.port)
payload = varint(0) + varint(777) + string(a.host) + struct.pack(">H", a.port) + varint(2)
c.s.sendall(varint(len(payload)) + payload); c.state = "login"
h = bytearray(hashlib.md5(("OfflinePlayer:" + a.name).encode()).digest()); h[6] = (h[6] & 0x0F) | 0x30; h[8] = (h[8] & 0x3F) | 0x80
c.send("minecraft:hello", string(a.name) + bytes(h))
fr = c.frames()
for n, body, _ in fr:
    if n == "minecraft:login_compression": c.threshold, _ = parse_varint(body)
    if n == "minecraft:login_finished": break
    if n == "minecraft:login_disconnect": sys.exit("login refused: " + body.decode(errors="replace"))
c.send("minecraft:login_acknowledged"); c.state = "configuration"
for n, body, _ in fr:
    if n == "minecraft:select_known_packs": c.send("minecraft:select_known_packs", varint(0))
    elif n == "minecraft:keep_alive": c.send("minecraft:keep_alive", body)
    elif n == "minecraft:ping": c.send("minecraft:pong", body)
    elif n == "minecraft:disconnect": sys.exit("disconnected in configuration")
    elif n == "minecraft:finish_configuration": break
c.send("minecraft:finish_configuration"); c.state = "play"
stop = False
signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__("stop", True))
end = time.time() + a.seconds; loaded = False; last_mark = 0.0
c.s.settimeout(30)
try:
    for n, body, wl in fr:
        k = c.counts.setdefault(n, [0, 0]); k[0] += 1; k[1] += wl
        if n == "minecraft:keep_alive": c.send("minecraft:keep_alive", body)
        elif n == "minecraft:ping": c.send("minecraft:pong", body)
        elif n == "minecraft:player_position":
            tid, o = parse_varint(body)
            c.send("minecraft:accept_teleportation", body[:o] + body[o:o + 24] + body[o + 48:o + 56])
            if not loaded: c.send("minecraft:player_loaded"); loaded = True
        elif n == "minecraft:chunk_batch_finished": c.send("minecraft:chunk_batch_received", struct.pack(">f", 20.0))
        elif n == "minecraft:disconnect": print("disconnected in play", file=sys.stderr); break
        now = time.time()
        if a.mark and now - last_mark >= 1.0:
            last_mark = now; tmp = a.mark + ".tmp"
            json.dump({"t": now, "counts": c.counts}, open(tmp, "w")); os.replace(tmp, a.mark)
        if now >= end or stop: break
except (socket.timeout, EOFError):
    pass
if a.out: json.dump({"t": time.time(), "counts": c.counts}, open(a.out, "w"))
tot = sum(v[1] for v in c.counts.values())
print(f"{sum(v[0] for v in c.counts.values())} packets, {tot} bytes", file=sys.stderr)
