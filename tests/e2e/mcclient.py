"""A small Minecraft 26.3 (protocol 777) client for tests: offline login, configuration, play, with the replies a real client sends automatically.
Standard library only.  Used against the real vanilla server (to record what it does) and against a dbcraft database (to compare).

    c = Client("127.0.0.1", 25599, "Probe")        # connects, logs in, reaches play
    c.send("set_creative_mode_slot", i16(36) + stack("minecraft:stone", 1))
    c.mark("placed")
    c.wait_for("minecraft:block_changed_ack", 3)
    c.events                                       # [{t, dir, state, id, name, hex (whole frame), body (bytes)}, ...]

Automatic replies in play: keep_alive, ping -> pong, player_position -> accept_teleportation (+ player_loaded once),
chunk_batch_finished -> chunk_batch_received.
"""
import hashlib, json, os, socket, struct, threading, time, zlib

REPORTS = os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports"))
_packets = json.load(open(os.path.join(REPORTS, "packets.json")))
ID, NAME = {}, {}
for _st, _dirs in _packets.items():
    for _d, _ps in _dirs.items():
        for _n, _e in _ps.items():
            ID[(_st, _d, _n)] = _e["protocol_id"]
            NAME[(_st, _d, _e["protocol_id"])] = _n
_registries = json.load(open(os.path.join(REPORTS, "registries.json")))
ITEM = {n: e["protocol_id"] for n, e in _registries["minecraft:item"]["entries"].items()}
_blocks = json.load(open(os.path.join(REPORTS, "blocks.json")))
BLOCK_STATE = {}          # 'minecraft:stone' -> default state id; with properties: 'minecraft:oak_log[axis=x]' -> id
STATE_NAME = {}           # id -> full name
for _bn, _b in _blocks.items():
    for _s in _b["states"]:
        sp = _s.get("properties", {})
        full = _bn + ("[" + ",".join(f"{k}={v}" for k, v in sp.items()) + "]" if sp else "")
        BLOCK_STATE[full] = _s["id"]
        STATE_NAME[_s["id"]] = full
        if _s.get("default"):
            BLOCK_STATE[_bn] = _s["id"]


def varint(n):
    n &= 0xFFFFFFFF
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def parse_varint(b, o=0):
    v = shift = 0
    while True:
        c = b[o]
        o += 1
        v |= (c & 0x7F) << shift
        if not c & 0x80:
            return v, o
        shift += 7


def string(s):
    b = s.encode()
    return varint(len(b)) + b


def i16(n):
    return struct.pack(">h", n)


def position(x, y, z):
    v = ((x & 0x3FFFFFF) << 38) | ((z & 0x3FFFFFF) << 12) | (y & 0xFFF)
    return struct.pack(">Q", v)


def unposition(b, o=0):
    v = struct.unpack(">Q", b[o:o + 8])[0]
    x = v >> 38
    if x >= 1 << 25:
        x -= 1 << 26
    z = (v >> 12) & 0x3FFFFFF
    if z >= 1 << 25:
        z -= 1 << 26
    y = v & 0xFFF
    if y >= 1 << 11:
        y -= 1 << 12
    return x, y, z


def stack(item, count):
    return varint(count) + varint(ITEM[item]) + varint(0) + varint(0)


def offline_uuid(name):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + name).encode()).digest())
    h[6] = (h[6] & 15) | 0x30
    h[8] = (h[8] & 0x3F) | 0x80
    return bytes(h)


class Client:
    def __init__(self, host, port, name, auto=True, timeout=10.0):
        self.name, self.host, self.port = name, host, port
        self.events, self.lock, self.state, self.threshold = [], threading.Lock(), "handshake", -1
        self.pos = None
        self.alive = True
        self._loaded_sent = False
        self.auto = auto
        self.t0 = time.time()
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.settimeout(0.3)
        pl = varint(0) + varint(777) + string(host) + struct.pack(">H", port) + varint(2)
        self.s.sendall(varint(len(pl)) + pl)
        self.state = "login"
        self.send("minecraft:hello", string(name) + offline_uuid(name))
        self._until("minecraft:login_finished", timeout)
        self.send("minecraft:login_acknowledged")
        self.state = "configuration"
        while True:
            n, body = self._until(None, timeout)
            if n == "minecraft:select_known_packs":
                self.send("minecraft:select_known_packs", varint(0))
            elif n == "minecraft:finish_configuration":
                break
            elif n == "minecraft:disconnect":
                raise RuntimeError("disconnected in configuration")
        self.send("minecraft:finish_configuration")
        self.state = "play"
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    # ---- wire
    def _read_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            try:
                c = self.s.recv(n - len(buf))
            except socket.timeout:
                if not self.alive:
                    raise EOFError
                continue
            if not c:
                raise EOFError
            buf += c
        return bytes(buf)

    def _read_frame(self):
        v = shift = 0
        while True:
            b = self._read_exact(1)[0]
            v |= (b & 0x7F) << shift
            if not b & 0x80:
                break
            shift += 7
        raw = self._read_exact(v)
        wire = varint(v) + raw
        if self.threshold >= 0:
            dl, o = parse_varint(raw)
            payload = raw[o:] if dl == 0 else zlib.decompress(raw[o:])
        else:
            payload = raw
        pid, o = parse_varint(payload)
        return pid, payload[o:], wire

    def _record(self, direction, state, pid, body, wire):
        name = NAME.get((state, direction, pid), f"id{pid}")
        e = {"t": round(time.time() - self.t0, 4), "dir": direction, "state": state, "id": pid, "name": name,
             "hex": wire.hex(), "body": body}
        with self.lock:
            self.events.append(e)
        return name

    def send(self, name, body=b""):
        pid = ID[(self.state, "serverbound", name)]
        payload = varint(pid) + body
        if self.threshold >= 0:
            if len(payload) < self.threshold:
                wire = varint(len(payload) + 1) + b"\x00" + payload
            else:
                z = zlib.compress(payload)
                wire = varint(len(varint(len(payload))) + len(z)) + varint(len(payload)) + z
        else:
            wire = varint(len(payload)) + payload
        try:
            self.s.sendall(wire)
        except OSError:
            self.alive = False
        self._record("serverbound", self.state, pid, body, wire)

    def mark(self, label):
        with self.lock:
            self.events.append({"t": round(time.time() - self.t0, 4), "dir": "", "state": "mark", "name": label,
                                "id": -1, "hex": "", "body": b""})

    def _until(self, want, timeout):
        end = time.time() + timeout
        while time.time() < end:
            try:
                pid, body, wire = self._read_frame()
            except EOFError:
                break
            name = self._record("clientbound", self.state, pid, body, wire)
            if name == "minecraft:login_compression":
                self.threshold = parse_varint(body)[0]
            if name == "minecraft:login_disconnect":
                raise RuntimeError("login refused: " + body.decode(errors="replace"))
            if want is None or name == want:
                return name, body
        raise TimeoutError(want)

    def _loop(self):
        while self.alive:
            try:
                pid, body, wire = self._read_frame()
            except (EOFError, OSError):
                self.alive = False
                break
            name = self._record("clientbound", "play", pid, body, wire)
            if not self.auto:
                continue
            if name == "minecraft:keep_alive":
                self.send("minecraft:keep_alive", body)
            elif name == "minecraft:ping":
                self.send("minecraft:pong", body)
            elif name == "minecraft:player_position":
                tid, o = parse_varint(body)
                x, y, z = struct.unpack(">ddd", body[o:o + 24])
                self.pos = (x, y, z)
                self.send("minecraft:accept_teleportation", body[:o] + body[o:o + 24] + body[o + 48:o + 56])
                if not self._loaded_sent:
                    self.send("minecraft:player_loaded")
                    self._loaded_sent = True
            elif name == "minecraft:chunk_batch_finished":
                self.send("minecraft:chunk_batch_received", struct.pack(">f", 20.0))
            elif name == "minecraft:disconnect":
                self.alive = False

    def wait_for(self, name, timeout=5.0, after=0):
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                for e in self.events[after:]:
                    if e["name"] == name and e["dir"] == "clientbound":
                        return e
            time.sleep(0.02)
        return None

    def count(self):
        with self.lock:
            return len(self.events)

    def since(self, k, kinds=None):
        with self.lock:
            ev = list(self.events[k:])
        return [e for e in ev if e["dir"] == "clientbound" and (kinds is None or e["name"] in kinds)]

    def settle(self, quiet=0.4, timeout=8.0):
        """wait until nothing new has arrived for `quiet` seconds"""
        end = time.time() + timeout
        last = self.count()
        t = time.time()
        while time.time() < end:
            time.sleep(0.05)
            n = self.count()
            if n != last:
                last, t = n, time.time()
            elif time.time() - t >= quiet:
                return

    def close(self):
        self.alive = False
        try:
            self.s.close()
        except OSError:
            pass

    def dump(self, path):
        with open(path, "w") as f:
            for e in self.events:
                f.write(json.dumps({k: v for k, v in e.items() if k != "body"}) + "\n")
