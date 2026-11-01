#!/usr/bin/env python3
"""Scripted multi-client probe for a vanilla 26.3 server (offline mode, no compression).  Records every packet each client RECEIVES, byte for byte,
so the SQL game logic can be compared with what the real server sends.

usage: tools/game_probe.py SCENARIO [--port 25598] [--out /tmp/game-scratch/cap]
scenarios: social   (Op joins, Bob joins, Bob moves/chats/sets a slot, Op runs commands, Bob leaves)
Output: <out>/<scenario>_<client>.jsonl  with {t, name, id, hex}  (hex is the whole frame incl. length prefix).
Captures contain Mojang data and stay out of git.  Standard library only.

Layouts used (read from the 26.3 bytecode with tools/pkt_layout.py, confirmed by the server accepting them):
  chat              = String(256) | Instant(long epoch ms) | salt long | Optional<signature 256 bytes> | lastSeen: VarInt offset, BitSet(20)=3 bytes, checksum byte
  chat_command      = String
  move_player_pos   = 3 doubles | flags byte      (flags: 1 = on ground, 2 = horizontal collision)
  move_player_pos_rot = 3 doubles | yRot float | xRot float | flags byte
  move_player_rot   = yRot float | xRot float | flags byte
  move_player_status_only = flags byte
  set_carried_item  = short slot
  set_creative_mode_slot = short slot | ItemStack (VarInt count [0 = empty], VarInt item registry id, VarInt added components, VarInt removed components)
  accept_teleportation = VarInt id | 3 doubles | 2 floats
"""
import argparse, hashlib, json, os, socket, struct, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("scenario"); ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25598)
ap.add_argument("--out", default="/tmp/game-scratch/cap")
args = ap.parse_args()
reports = os.environ.get("DBCRAFT_REPORTS", "/home/user/atyr647/adacraft/generated/26.3/reports")
packets = json.load(open(os.path.join(reports, "packets.json")))
registries = json.load(open(os.path.join(reports, "registries.json")))
ID, NAME = {}, {}
for st, dirs in packets.items():
    for d, ps in dirs.items():
        for n, e in ps.items(): ID[(st, d, n)] = e["protocol_id"]; NAME[(st, d, e["protocol_id"])] = n
ITEM = {n: e["protocol_id"] for n, e in registries["minecraft:item"]["entries"].items()}

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
def offline_uuid(name):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + name).encode()).digest()); h[6] = (h[6] & 15) | 0x30; h[8] = (h[8] & 0x3F) | 0x80
    return bytes(h)

class Client:
    def __init__(self, name):
        self.name = name; self.events = []; self.state = "login"; self.alive = True; self.pos = None; self.lock = threading.Lock()
        self.s = socket.create_connection((args.host, args.port)); self.s.settimeout(0.2); self.t0 = time.time()
        pl = varint(0) + varint(777) + string(args.host) + struct.pack(">H", args.port) + varint(2)
        self.s.sendall(varint(len(pl)) + pl)
        self._send_raw("login", "minecraft:hello", string(name) + offline_uuid(name))
        self._until("minecraft:login_finished"); self._send_raw("login", "minecraft:login_acknowledged", b""); self.state = "configuration"
        while True:
            n, body = self._recv_blocking()
            if n == "minecraft:select_known_packs": self._send_raw("configuration", "minecraft:select_known_packs", varint(0))
            elif n == "minecraft:finish_configuration": break
        self._send_raw("configuration", "minecraft:finish_configuration", b""); self.state = "play"
        self.thread = threading.Thread(target=self._loop, daemon=True); self.thread.start()
        self.tick_end = True
        threading.Thread(target=self._ticker, daemon=True).start()
    def _send_raw(self, state, name, body):
        payload = varint(ID[(state, "serverbound", name)]) + body
        try:
            with self.lock: self.s.sendall(varint(len(payload)) + payload)
        except OSError:
            self.events.append({"t": round(time.time() - self.t0, 3), "state": "mark", "name": "SEND FAILED (server closed): " + name, "id": -1, "hex": ""})
    def send(self, name, body=b""): self._send_raw("play", "minecraft:" + name, body)
    def _read(self):
        v = shift = 0
        while True:
            b = self.s.recv(1)
            if not b: raise EOFError
            v |= (b[0] & 0x7F) << shift
            if not b[0] & 0x80: break
            shift += 7
        buf = bytearray()
        while len(buf) < v:
            c = self.s.recv(v - len(buf))
            if not c: raise EOFError
            buf += c
        return varint(v) + bytes(buf), bytes(buf)
    def _recv_blocking(self):
        while True:
            try: wire, raw = self._read()
            except socket.timeout: continue
            pid, o = parse_varint(raw); n = NAME.get((self.state, "clientbound", pid), "?")
            self.events.append({"t": round(time.time() - self.t0, 3), "state": self.state, "name": n, "id": pid, "hex": wire.hex()})
            return n, raw[o:]
    def _until(self, name):
        while True:
            n, body = self._recv_blocking()
            if n == name: return body
            if n == "minecraft:login_disconnect": sys.exit("refused: " + body.decode(errors="replace"))
    def _ticker(self):
        while self.alive:
            time.sleep(0.05)
            if self.tick_end and self.state == "play": self.send("client_tick_end")
    def _loop(self):
        while self.alive:
            try: n, body = self._recv_blocking()
            except (EOFError, OSError): break
            if n == "minecraft:keep_alive": self.send("keep_alive", body)
            elif n == "minecraft:ping": self.send("pong", body)
            elif n == "minecraft:player_position":
                tid, o = parse_varint(body); self.pos = struct.unpack(">ddd", body[o:o + 24])
                self.send("accept_teleportation", body[:o] + body[o:o + 24] + body[o + 48:o + 56]); self.send("player_loaded")
            elif n == "minecraft:chunk_batch_finished": self.send("chunk_batch_received", struct.pack(">f", 20.0))
    # --- actions
    def chat(self, msg): self.send("chat", string(msg) + struct.pack(">q", int(time.time() * 1000)) + struct.pack(">q", 0) + b"\x00" + varint(0) + b"\x00\x00\x00" + b"\x00")
    def command(self, cmd): self.send("chat_command", string(cmd))
    def pos_(self, x, y, z, flags=1): self.send("move_player_pos", struct.pack(">ddd", x, y, z) + bytes([flags]))
    def pos_rot(self, x, y, z, yaw, pitch, flags=1): self.send("move_player_pos_rot", struct.pack(">dddff", x, y, z, yaw, pitch) + bytes([flags]))
    def rot(self, yaw, pitch, flags=1): self.send("move_player_rot", struct.pack(">ff", yaw, pitch) + bytes([flags]))
    def status(self, flags=1): self.send("move_player_status_only", bytes([flags]))
    def held(self, slot): self.send("set_carried_item", struct.pack(">h", slot))
    def creative_slot(self, slot, item, count): self.send("set_creative_mode_slot", struct.pack(">h", slot) + varint(count) + (varint(ITEM[item]) + varint(0) + varint(0) if count else b""))
    def mark(self, label): self.events.append({"t": round(time.time() - self.t0, 3), "state": "mark", "name": label, "id": -1, "hex": ""})
    def close(self):
        self.alive = False
        try: self.s.close()
        except OSError: pass
    def save(self, scenario):
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, f"{scenario}_{self.name}.jsonl"), "w") as f:
            for e in self.events: f.write(json.dumps(e) + "\n")

def social():
    op = Client("Op"); time.sleep(2.5); op.mark("bob joins")
    bob = Client("Bob"); time.sleep(2.5)
    bp = bob.pos or (0.5, -60.0, 0.5)
    op.mark("bob moves"); bob.mark("bob moves")
    bob.pos_(bp[0] + 1.0, bp[1], bp[2], 1); time.sleep(0.15)
    bob.pos_rot(bp[0] + 1.5, bp[1], bp[2] + 0.5, 90.0, 10.0, 1); time.sleep(0.15)
    bob.rot(180.0, -20.0, 1); time.sleep(0.15)
    bob.status(0); time.sleep(0.15)
    bob.pos_(bp[0] + 40.0, bp[1], bp[2], 1); time.sleep(0.6)        # a large jump: what does the real server do?
    op.mark("bob chats"); bob.mark("bob chats"); bob.chat("hello world"); time.sleep(0.5)
    bob.mark("bob slot"); bob.creative_slot(36, "minecraft:stone", 5); time.sleep(0.2); bob.held(3); time.sleep(0.4)
    op.mark("commands")
    for c in ("list", "seed", "time set day", "weather clear", "gamemode survival Bob", "gamemode creative Bob", "say hi there", "tp Bob 10 -60 10",
              "give Bob minecraft:stone 3", "kill Bob", "whitelist list", "op Bob", "deop Bob", "difficulty peaceful", "nosuchcommand", "msg Bob secret"):
        bob.mark("cmd " + c); op.mark("cmd " + c); op.command(c); time.sleep(0.5)
    bob.mark("bob leaves"); op.mark("bob leaves"); bob.close(); time.sleep(1.5)
    op.close(); bob.save("social"); op.save("social")
    for cl in (op, bob):
        from collections import Counter
        c = Counter(e["name"] for e in cl.events if e["state"] == "play")
        print(cl.name, len(cl.events), "events:", dict(c))

def movetest():
    """Send each move packet type on a fresh connection; report which ones the real server accepts."""
    tests = {
      "pos":        lambda c, p: c.pos_(p[0] + 0.5, p[1], p[2], 1),
      "pos_rot":    lambda c, p: c.pos_rot(p[0] + 0.5, p[1], p[2], 90.0, 10.0, 1),
      "rot":        lambda c, p: c.rot(180.0, -20.0, 1),
      "status(1)":  lambda c, p: c.status(1),
      "status(0)":  lambda c, p: c.status(0),
      "pos 40 away": lambda c, p: c.pos_(p[0] + 40.0, p[1], p[2], 1),
      "pos NaN":    lambda c, p: c.pos_(float("nan"), p[1], p[2], 1),
      "rot yaw 400": lambda c, p: c.rot(400.0, 0.0, 1),
      "rot pitch 120": lambda c, p: c.rot(0.0, 120.0, 1),
      "pos 3.1e7":  lambda c, p: c.pos_(3.1e7, p[1], p[2], 1),
    }
    for i, (name, f) in enumerate(tests.items()):
        c = Client(f"M{i}"); time.sleep(2.0); p = c.pos or (0.5, -60.0, 0.5)
        try: f(c, p); time.sleep(0.6); c.status(1); time.sleep(0.3); ok = True
        except (BrokenPipeError, ConnectionError, OSError): ok = False
        c.close(); print(f"{name:14s} {'accepted' if ok else 'REJECTED (connection closed)'}  events after: {sorted(set(e['name'] for e in c.events[-12:] if e['state']=='play'))[:5]}")

def moveseq():
    """Replay the first moves of `social` one step at a time, reporting the first step after which the server closes the connection."""
    c = Client("Seq"); time.sleep(2.5); p = c.pos or (0.5, -60.0, 0.5)
    steps = [("pos +1.0", lambda: c.pos_(p[0] + 1.0, p[1], p[2], 1)),
             ("pos_rot +1.5,+0.5 yaw90", lambda: c.pos_rot(p[0] + 1.5, p[1], p[2] + 0.5, 90.0, 10.0, 1)),
             ("rot 180/-20", lambda: c.rot(180.0, -20.0, 1)), ("status 0", lambda: c.status(0))]
    for name, f in steps:
        n0 = len([e for e in c.events if e["name"].startswith("SEND FAILED")]); f(); time.sleep(0.4)
        dead = any(e["name"] == "minecraft:disconnect" for e in c.events)
        print(f"{name:28s} -> {'SERVER DISCONNECTED' if dead else 'ok'}")
        if dead:
            d = [e for e in c.events if e["name"] == "minecraft:disconnect"][0]; print("   ", bytes.fromhex(d["hex"])[-60:]); break
    c.close()

def moveseq2():
    """Which pairs of consecutive move packets does the real server reject?"""
    seqs = {
      "pos, pos":          [("pos", (1.0, 0, 0)), ("pos", (1.5, 0, 0.5))],
      "pos_rot, pos_rot":  [("pr", (1.0, 0, 0, 90.0, 10.0)), ("pr", (1.5, 0, 0.5, 90.0, 10.0))],
      "pos, pos_rot":      [("pos", (1.0, 0, 0)), ("pr", (1.5, 0, 0.5, 90.0, 10.0))],
      "pos, pos_rot (wait 1s)": [("pos", (1.0, 0, 0)), ("wait", 1.0), ("pr", (1.5, 0, 0.5, 90.0, 10.0))],
      "pos, pos_rot same xz":   [("pos", (1.0, 0, 0)), ("pr", (1.0, 0, 0, 90.0, 10.0))],
      "pos, pos_rot yaw 0":     [("pos", (1.0, 0, 0)), ("pr", (1.5, 0, 0.5, 0.0, 0.0))],
    }
    for i, (name, seq) in enumerate(seqs.items()):
        c = Client(f"S{i}"); time.sleep(2.0); p = c.pos or (0.5, -60.0, 0.5)
        for kind, a in seq:
            if kind == "pos": c.pos_(p[0] + a[0], p[1] + a[1], p[2] + a[2], 1)
            elif kind == "pr": c.pos_rot(p[0] + a[0], p[1] + a[1], p[2] + a[2], a[3], a[4], 1)
            else: time.sleep(a); continue
            time.sleep(0.25)
        time.sleep(0.4); dead = [e for e in c.events if e["name"] == "minecraft:disconnect"]
        print(f"{name:26s} -> {'REJECTED: ' + bytes.fromhex(dead[0]['hex'])[-45:-1].decode(errors='replace') if dead else 'ok'}"); c.close()

def moveseq3():
    """Without client_tick_end between packets: which packet kinds (and how many) does the real server tolerate per client tick?"""
    A = {"pos": lambda c, p: c.pos_(p[0] + 0.1, p[1], p[2], 1), "pr": lambda c, p: c.pos_rot(p[0] + 0.1, p[1], p[2], 10.0, 5.0, 1),
         "rot": lambda c, p: c.rot(20.0, 5.0, 1), "st": lambda c, p: c.status(1)}
    for i, seq in enumerate([["rot", "rot"], ["st", "st"], ["pos", "st"], ["st", "pos"], ["rot", "pos"], ["pos", "rot"], ["st", "st", "st", "st", "st"], ["rot", "rot", "rot"]]):
        c = Client(f"T{i}"); time.sleep(2.0); c.tick_end = False; time.sleep(0.3); p = c.pos or (0.5, -60.0, 0.5)
        for k in seq: A[k](c, p)
        time.sleep(0.6); dead = [e for e in c.events if e["name"] == "minecraft:disconnect"]
        print(f"{'+'.join(seq):22s} -> {'REJECTED' if dead else 'ok'}"); c.close()

{"social": social, "movetest": movetest, "moveseq": moveseq, "moveseq2": moveseq2, "moveseq3": moveseq3}[args.scenario]()
