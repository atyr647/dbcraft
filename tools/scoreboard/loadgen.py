#!/usr/bin/env python3
"""Load generator: N scripted 26.3 clients (offline login, configuration, play) against ANY server (vanilla or dbcraft).  Standard library only.

Each client does what a real client does every tick: answers keep-alive/ping/teleport/chunk batches, sends client_tick_end 20 times a second, and (if it
walks) one move_player_pos per tick at a realistic speed in a random heading that changes every few seconds.  It parses only the packets it must answer
and skips the rest of every frame, so one process carries a few hundred clients.

usage (one process; the runner starts several for big N):
  loadgen.py --port P --n N --first I --prefix Bot --join-spread S --moving F --ready-timeout T --hold H [--probe] [--no-walk-after-ready]
Protocol with the runner on stdout/stdin (one JSON object per line):
  {"event":"READY", ...}   all (or --ready-frac of the) clients are in play and their chunks have stopped arriving   -> runner replies "GO\n"
  {"event":"DONE", ...}    after --hold seconds of steady state (clients keep their tick traffic and walking), final statistics
"""
import argparse, asyncio, hashlib, json, math, os, random, struct, sys, time

REPORTS = os.environ.get("DBCRAFT_REPORTS", "/home/user/atyr647/adacraft/generated/26.3/reports")
_packets = json.load(open(os.path.join(REPORTS, "packets.json")))
SB = {}                 # (state, name) -> id   serverbound
CB = {}                 # state -> {id: name}   clientbound
for _st, _dirs in _packets.items():
    for _d, _ps in _dirs.items():
        for _n, _e in _ps.items():
            if _d == "serverbound":
                SB[(_st, _n)] = _e["protocol_id"]
            else:
                CB.setdefault(_st, {})[_e["protocol_id"]] = _n

INTEREST = {
    "login": {"minecraft:login_finished", "minecraft:login_disconnect", "minecraft:login_compression"},
    "configuration": {"minecraft:select_known_packs", "minecraft:finish_configuration", "minecraft:keep_alive", "minecraft:ping", "minecraft:disconnect"},
    "play": {"minecraft:keep_alive", "minecraft:ping", "minecraft:player_position", "minecraft:chunk_batch_finished", "minecraft:login",
             "minecraft:disconnect"},
}
CHUNK = "minecraft:level_chunk_with_light"
SPEED = 4.317 / 20.0    # blocks per tick: walking speed of a player


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


def read_varint(buf, pos):
    v = shift = 0
    n = len(buf)
    while True:
        if pos >= n:
            return None, pos
        c = buf[pos]
        pos += 1
        v |= (c & 0x7F) << shift
        if not c & 0x80:
            return v, pos
        shift += 7
        if shift > 35:
            raise ValueError("bad varint")


def frame(state, name, body=b""):
    payload = varint(SB[(state, name)]) + body
    return varint(len(payload)) + payload


def string(s):
    b = s.encode()
    return varint(len(b)) + b


def offline_uuid(name):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + name).encode()).digest())
    h[6] = (h[6] & 0x0F) | 0x30
    h[8] = (h[8] & 0x3F) | 0x80
    return bytes(h)


class Client(asyncio.Protocol):
    def __init__(self, idx, name, args, port, probe=False):
        self.idx, self.name, self.args, self.port, self.probe = idx, name, args, port, probe
        self.state = "handshake"
        self.buf = bytearray()
        self.skip = 0
        self.tr = None
        self.alive = False
        self.failed = None
        self.t_connect = self.t_login = self.t_play = self.t_first_chunk = self.t_last_chunk = None
        self.chunks = 0
        self.batches = 0
        self.rx = 0
        self.x = self.y = self.z = None
        self.loaded_sent = False
        self.walk = False
        self.heading = random.uniform(0, 2 * math.pi)
        self.turn_at = 0
        self.rtts = []
        self.rtt_log = []        # (wall clock seconds when the chat was sent, round trip ms): the probe's samples with their time
        self.sent_wall = 0.0
        self.next_send = 0.0
        self.pending_token = None
        self.sent_at = 0.0
        self.disconnect_info = None
        self.t_failed = None

    # ---- connection
    def connection_made(self, tr):
        self.tr = tr
        self.alive = True
        self.t_connect = time.perf_counter()
        hs = varint(SB[("handshake", "minecraft:intention")]) + varint(777) + string("127.0.0.1") + struct.pack(">H", self.port) + varint(2)
        hello = frame("login", "minecraft:hello", string(self.name) + offline_uuid(self.name))
        tr.write(varint(len(hs)) + hs + hello)
        self.state = "login"

    def connection_lost(self, exc):
        self.alive = False
        if self.failed is None and self.state != "closing":
            self.failed = "closed" if exc is None else repr(exc)

    def send(self, name, body=b""):
        if self.alive:
            self.tr.write(frame(self.state, name, body))

    # ---- receive
    def data_received(self, data):
        self.rx += len(data)
        buf = self.buf
        buf += data
        pos = 0
        names = CB[self.state]
        interest = INTEREST[self.state]
        while True:
            if self.skip:
                n = min(self.skip, len(buf) - pos)
                self.skip -= n
                pos += n
                if self.skip:
                    break
                continue
            ln, p = read_varint(buf, pos)
            if ln is None:
                break
            pid, p2 = read_varint(buf, p)
            if pid is None:
                break
            name = names.get(pid, "?")
            if name in interest or (self.probe and self.state == "play" and name in ("minecraft:player_chat", "minecraft:system_chat")):
                if len(buf) - p < ln:
                    break
                body = bytes(buf[p2:p + ln])
                pos = p + ln
                self.on_packet(name, body)
                names = CB[self.state]
                interest = INTEREST[self.state]
            else:
                if name == CHUNK:
                    now = time.perf_counter()
                    self.chunks += 1
                    self.t_last_chunk = now
                    if self.t_first_chunk is None:
                        self.t_first_chunk = now
                self.skip = ln - (p2 - p)
                pos = p2
        del buf[:pos]

    def on_packet(self, name, body):
        st = self.state
        if st == "login":
            if name == "minecraft:login_finished":
                self.t_login = time.perf_counter()
                self.send("minecraft:login_acknowledged")
                self.state = "configuration"
                # a real client announces its settings here; vanilla serves min(server view distance, the client's), and the default is 2
                self.send("minecraft:client_information", string("en_us") + bytes([self.args.view_distance]) + varint(0) + b"\x01" + bytes([0x7F]) +
                          varint(1) + b"\x00" + b"\x01" + varint(0))
            elif name == "minecraft:login_disconnect":
                self.failed = "login_disconnect " + body[:100].hex()
            elif name == "minecraft:login_compression":
                self.failed = "compression is on: the scoreboard runs both servers uncompressed"
        elif st == "configuration":
            if name == "minecraft:select_known_packs":
                self.send("minecraft:select_known_packs", varint(0))
            elif name == "minecraft:finish_configuration":
                self.send("minecraft:finish_configuration")
                self.state = "play"
            elif name == "minecraft:keep_alive":
                self.send("minecraft:keep_alive", body)
            elif name == "minecraft:ping":
                self.send("minecraft:pong", body)
            elif name == "minecraft:disconnect":
                self.failed = "disconnect in configuration"
        else:
            if name == "minecraft:keep_alive":
                self.send("minecraft:keep_alive", body)
            elif name == "minecraft:ping":
                self.send("minecraft:pong", body)
            elif name == "minecraft:player_position":
                tid, o = read_varint(body, 0)
                self.x, self.y, self.z = struct.unpack(">ddd", body[o:o + 24])
                self.send("minecraft:accept_teleportation", body[:o] + body[o:o + 24] + body[o + 48:o + 56])
                if not self.loaded_sent:
                    self.loaded_sent = True
                    self.send("minecraft:player_loaded")
            elif name == "minecraft:chunk_batch_finished":
                self.batches += 1
                self.send("minecraft:chunk_batch_received", struct.pack(">f", 20.0))
            elif name == "minecraft:login":
                self.t_play = time.perf_counter()
            elif name in ("minecraft:player_chat", "minecraft:system_chat"):
                if self.pending_token and self.pending_token in body:
                    self.rtts.append((time.perf_counter() - self.sent_at) * 1000.0)
                    self.rtt_log.append((self.sent_wall, self.rtts[-1]))
                    self.pending_token = None
            elif name == "minecraft:disconnect":
                self.failed = "disconnect in play"
                self.disconnect_info = "".join(chr(b) if 32 <= b < 127 else "." for b in body[:200])     # the text component's keys are readable in the NBT
                self.t_failed = time.perf_counter()

    # ---- behaviour, called once per tick
    def tick(self, now):
        if self.state != "play" or not self.alive or self.x is None:
            return
        out = frame("play", "minecraft:client_tick_end")
        if self.walk:
            if now >= self.turn_at:
                self.heading = random.uniform(0, 2 * math.pi)
                self.turn_at = now + random.uniform(3.0, 8.0)
            self.x += math.cos(self.heading) * SPEED
            self.z += math.sin(self.heading) * SPEED
            b = self.args.bound
            if b and (abs(self.x) > b or abs(self.z) > b):      # stay inside the explored area: turn back towards the origin
                self.heading = math.atan2(-self.z, -self.x) + random.uniform(-0.6, 0.6)
                self.turn_at = now + random.uniform(2.0, 5.0)
            out += frame("play", "minecraft:move_player_pos", struct.pack(">dddB", self.x, self.y, self.z, 1))
        self.tr.write(out)

    def send_chat(self, token):
        self.pending_token = token.encode()
        self.sent_at = time.perf_counter()
        self.sent_wall = time.time()
        body = string(token) + struct.pack(">q", int(time.time() * 1000)) + struct.pack(">q", 0) + b"\x00" + varint(0) + b"\x00\x00\x00" + b"\x00"
        self.send("minecraft:chat", body)

    def ready(self, now, quiet, expect=0):
        """In play, spawned, and its chunks have arrived: the expected count if given, else a quiet period; a long quiet period always counts."""
        if not (self.state == "play" and self.t_play is not None and self.batches >= 1 and self.x is not None and self.t_last_chunk is not None):
            return False
        if expect and self.chunks >= expect:
            return True
        return now - self.t_last_chunk >= (max(quiet, 40.0) if expect else quiet)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--n", type=int, default=10)
    ap.add_argument("--first", type=int, default=0)
    ap.add_argument("--prefix", default="Bot")
    ap.add_argument("--join-spread", type=float, default=0.0, help="seconds over which the connections are opened (1 = a login storm)")
    ap.add_argument("--moving", type=float, default=0.0, help="fraction of the clients that walk")
    ap.add_argument("--ready-timeout", type=float, default=120.0)
    ap.add_argument("--ready-frac", type=float, default=0.97)
    ap.add_argument("--quiet", type=float, default=2.0, help="seconds without a chunk packet before a client counts as ready")
    ap.add_argument("--expect-chunks", type=int, default=0, help="chunks a client must have received to count as ready: (2*(view distance+1)+1)^2")
    ap.add_argument("--view-distance", type=int, default=10, help="view distance the clients ask for in client_information")
    ap.add_argument("--bound", type=float, default=0.0, help="walkers turn back when they pass +-bound blocks (0 = they walk on: they leave the explored area)")
    ap.add_argument("--hold", type=float, default=30.0)
    ap.add_argument("--probe", action="store_true", help="add one chat-echo round-trip probe client")
    ap.add_argument("--probe-interval", type=float, default=1.0, help="seconds between the probe's chat messages (a new one is sent only after the previous came back, or after 10 s)")
    ap.add_argument("--probes", type=int, default=1, help="with --probe: how many probe clients (named Probe<first>, Probe<first>_1, ...); each chats every --probe-interval seconds, evenly staggered.  "
                    "Vanilla kicks a player for chat spam above about one message per second, so a finer time resolution needs several probes")
    ap.add_argument("--no-go", action="store_true", help="do not wait for GO on stdin")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    random.seed(args.seed + args.first)
    loop = asyncio.get_running_loop()
    clients = []
    t0 = time.perf_counter()

    async def open_client(i, delay, probe=False, pk=0):
        await asyncio.sleep(delay)
        name = (("Probe%d" % args.first) + ("_%d" % pk if pk else "")) if probe else "%s%d" % (args.prefix, i)
        c = Client(i, name, args, args.port, probe)
        clients.append(c)
        try:
            await loop.create_connection(lambda: c, args.host, args.port)
        except Exception as e:
            c.failed = "connect failed: " + repr(e)

    tasks = []
    for k in range(args.n):
        delay = (k / max(1, args.n)) * args.join_spread
        tasks.append(asyncio.ensure_future(open_client(args.first + k, delay)))
    if args.probe:
        for k in range(args.probes):
            tasks.append(asyncio.ensure_future(open_client(900000 + args.first + k, 0.0, True, k)))
    movers = set(random.sample(range(args.n), int(round(args.n * args.moving)))) if args.moving > 0 else set()

    ticking = {"on": False}

    async def ticker():
        nxt = time.perf_counter()
        while True:
            nxt += 0.05
            now = time.perf_counter()
            if ticking["on"]:
                for c in clients:
                    c.tick(now)
            await asyncio.sleep(max(0.0, nxt - time.perf_counter()))

    ticker_task = asyncio.ensure_future(ticker())

    def summary(final=False):
        now = time.perf_counter()
        regular = [c for c in clients if not c.probe]
        inplay = sum(1 for c in regular if c.state == "play" and c.t_play is not None)
        ready = sum(1 for c in regular if c.ready(now, args.quiet, args.expect_chunks))
        failed = [c for c in regular if c.failed]
        d = {"t": now - t0, "clients": len(regular), "in_play": inplay, "ready": ready, "failed": len(failed)}
        if final:
            jl = [c.t_play - c.t_connect for c in regular if c.t_play]
            tl = [c.t_last_chunk - c.t_connect for c in regular if c.t_last_chunk]
            d["join_to_play_s"] = jl
            d["join_to_last_chunk_s"] = tl
            d["chunks_per_client"] = [c.chunks for c in regular]
            d["rx_bytes"] = sum(c.rx for c in clients)
            d["failures"] = {}
            for c in failed:
                d["failures"][c.failed] = d["failures"].get(c.failed, 0) + 1
            d["rtt_ms"] = [r for c in clients if c.probe for r in c.rtts]
            d["rtt_log"] = [[round(t, 3), round(r, 2)] for c in clients if c.probe for t, r in c.rtt_log]
            reasons = {}
            for c in failed:
                if c.disconnect_info:
                    reasons[c.disconnect_info[:120]] = reasons.get(c.disconnect_info[:120], 0) + 1
            d["disconnect_reasons"] = reasons
            tf = sorted(c.t_failed - t0 for c in failed if c.t_failed)
            d["failure_times_s"] = [round(tf[0], 1), round(tf[len(tf) // 2], 1), round(tf[-1], 1)] if tf else []
        return d

    # ---- wait until ready
    deadline = t0 + args.ready_timeout
    last_report = 0
    while True:
        await asyncio.sleep(0.25)
        s = summary()
        if time.perf_counter() - last_report > 5:
            last_report = time.perf_counter()
            print(json.dumps({"event": "progress", **s}), flush=True)
        if s["clients"] >= args.n and s["ready"] >= args.ready_frac * args.n and (not args.probe or any(c.probe and c.state == "play" and c.x is not None for c in clients)):
            break
        if time.perf_counter() > deadline:
            break
    ready_summary = summary()
    ready_summary["timed_out"] = time.perf_counter() > deadline
    for k, c in enumerate([c for c in clients if not c.probe]):
        c.walk = (c.idx - args.first) in movers
    ticking["on"] = True
    print(json.dumps({"event": "READY", **ready_summary}), flush=True)

    if not args.no_go:
        await loop.run_in_executor(None, sys.stdin.readline)

    # ---- steady state (ends after --hold seconds, or when the runner writes STOP)
    stop_fut = loop.run_in_executor(None, sys.stdin.readline) if not args.no_go else None
    hold_end = time.perf_counter() + args.hold
    n = 0
    probes = [c for c in clients if c.probe]
    t_go = time.perf_counter()
    for k, c in enumerate(probes):
        c.next_send = t_go + (k / max(1, len(probes))) * args.probe_interval
    while time.perf_counter() < hold_end and not (stop_fut is not None and stop_fut.done()):
        await asyncio.sleep(0.02 if probes else 1.0)
        now = time.perf_counter()
        for c in probes:
            if c.alive and c.state == "play" and now >= c.next_send and (c.pending_token is None or now - c.sent_at > 10.0):
                if c.pending_token is not None:                 # the echo never came back: count it as a 10 s round trip
                    c.rtts.append(10000.0)
                    c.rtt_log.append((c.sent_wall, 10000.0))
                n += 1
                c.send_chat("p%d_%d_%d" % (args.first, n, id(c) % 997))
                c.next_send = max(c.next_send + args.probe_interval, now)
    await asyncio.sleep(0.5)
    final = summary(final=True)
    print(json.dumps({"event": "DONE", **final}), flush=True)
    ticker_task.cancel()
    for c in clients:
        c.state = "closing"
        if c.tr:
            c.tr.close()
    await asyncio.sleep(0.3)


if __name__ == "__main__":
    asyncio.run(main())
