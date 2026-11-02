#!/usr/bin/env python3
"""Load generator: N simulated clients doing the REAL offline join (handshake, login, configuration with the registry burst, play entry, chunks) and then playing:
every client sends client_tick_end each game tick, a fraction also walks (move_player_pos at 4.3 blocks/s, alternating with client_tick_end as the real client does), a few
"probe" clients measure the end-to-end latency (input -> gateway -> database tick -> gateway -> output) by sending a jump beyond the server's limit and timing the corrective
teleport.  Python asyncio: one process generates a few thousand packets per second, so use --procs to spread the clients over processes (and see 'achieved' in the report).

usage: load_clients.py PORT N [--host 127.0.0.1] [--moving 0.2] [--seconds 20] [--ramp 100] [--hz 20] [--probes 10] [--procs 1] [--prefix L] [--join-timeout 120]
output: one JSON line (also human readable on stderr): joined/failed/dropped counts, join time and probe latency percentiles, packets and bytes, achieved rates.
"""
import argparse, asyncio, hashlib, json, math, os, struct, sys, time
from multiprocessing import Process, Queue

REPORTS = os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports"))
P = json.load(open(os.path.join(REPORTS, "packets.json")))
ID = {(st, d, n): e["protocol_id"] for st, dirs in P.items() for d, ps in dirs.items() for n, e in ps.items()}
NAME = {(st, d, e["protocol_id"]): n for st, dirs in P.items() for d, ps in dirs.items() for n, e in ps.items()}


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


def offline_uuid(name):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + name).encode()).digest())
    h[6] = (h[6] & 0x0F) | 0x30
    h[8] = (h[8] & 0x3F) | 0x80
    return bytes(h)


def frame(state, name, body=b""):
    p = varint(ID[(state, "serverbound", "minecraft:" + name)]) + body
    return varint(len(p)) + p


async def read_frame(r):
    n = shift = 0
    while True:
        b = (await r.readexactly(1))[0]
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            break
        shift += 7
    return await r.readexactly(n)


class Stats:
    def __init__(self):
        self.joined = 0
        self.failed = 0
        self.dropped = 0
        self.join_ms = []
        self.probe_ms = []
        self.frames_in = 0
        self.bytes_in = 0
        self.frames_out = 0


async def one_client(i, a, st, t_end_box, moving, probe):
    name = f"{a.prefix}{i:05d}"[:16]
    t0 = time.perf_counter()
    try:
        r, w = await asyncio.wait_for(asyncio.open_connection(a.host, a.port), 30)
    except Exception:
        st.failed += 1
        return
    state = "login"
    joined = False
    sent_loaded = False
    x, y, z = 0.5, -60.0, 0.5
    heading = (i * 2.399963) % (2 * math.pi)       # a different direction per client
    probe_t = None
    mover = None

    def send(s, n, body=b""):
        w.write(frame(s, n, body))
        st.frames_out += 1

    async def play_loop():
        nonlocal x, z, probe_t
        step = 4.317 / a.hz                           # blocks per client tick at walking speed
        nxt = time.perf_counter()
        k = 0
        last_probe = time.perf_counter()
        while time.perf_counter() < t_end_box[0]:
            nxt += 1.0 / a.hz
            k += 1
            if moving:
                x += math.cos(heading) * step
                z += math.sin(heading) * step
                send("play", "move_player_pos", struct.pack(">ddd", x, y, z) + b"\x01")
            elif probe and probe_t is None and time.perf_counter() - last_probe > 1.0:
                last_probe = time.perf_counter()
                probe_t = last_probe
                send("play", "move_player_pos", struct.pack(">ddd", x + 10.5, y, z) + b"\x00")   # beyond the limit: the server answers with a corrective teleport
            send("play", "client_tick_end")
            try:
                await w.drain()
            except Exception:
                return
            d = nxt - time.perf_counter()
            if d > 0:
                await asyncio.sleep(d)

    try:
        hs = varint(0) + varint(777) + varint(len(a.host)) + a.host.encode() + struct.pack(">H", a.port) + varint(2)
        w.write(varint(len(hs)) + hs)
        send("login", "hello", varint(len(name)) + name.encode() + offline_uuid(name))
        while True:
            body = await asyncio.wait_for(read_frame(r), a.join_timeout if not joined else 60)
            st.frames_in += 1
            st.bytes_in += len(body) + 3
            pid, o = parse_varint(body)
            n = NAME.get((state, "clientbound", pid), "?")
            if state == "login":
                if n == "minecraft:login_finished":
                    send("login", "login_acknowledged")
                    state = "configuration"
                elif n == "minecraft:login_disconnect":
                    raise RuntimeError("login refused: " + body[o:o + 200].decode("latin1"))
            elif state == "configuration":
                if n == "minecraft:select_known_packs":
                    send("configuration", "select_known_packs", varint(0))
                elif n == "minecraft:keep_alive":
                    send("configuration", "keep_alive", body[o:o + 8])
                elif n == "minecraft:ping":
                    send("configuration", "pong", body[o:o + 4])
                elif n == "minecraft:disconnect":
                    raise RuntimeError("disconnected in configuration")
                elif n == "minecraft:finish_configuration":
                    send("configuration", "finish_configuration")
                    state = "play"
            elif state == "play":
                if n == "minecraft:keep_alive":
                    send("play", "keep_alive", body[o:o + 8])
                elif n == "minecraft:ping":
                    send("play", "pong", body[o:o + 4])
                elif n == "minecraft:player_position":
                    tid, o2 = parse_varint(body, o)
                    send("play", "accept_teleportation", body[o:o2] + body[o2:o2 + 24] + body[o2 + 48:o2 + 56])
                    px, py, pz = struct.unpack(">ddd", body[o2:o2 + 24])
                    x, y, z = px, py, pz
                    if not sent_loaded:
                        sent_loaded = True
                        send("play", "player_loaded")
                    if probe_t is not None and joined:
                        st.probe_ms.append((time.perf_counter() - probe_t) * 1000)
                        probe_t = None
                elif n == "minecraft:chunk_batch_finished":
                    send("play", "chunk_batch_received", struct.pack(">f", 20.0))
                    if not joined:
                        joined = True
                        st.joined += 1
                        st.join_ms.append((time.perf_counter() - t0) * 1000)
                        mover = asyncio.ensure_future(play_loop())
                elif n == "minecraft:disconnect":
                    raise RuntimeError("disconnected in play")
            if time.perf_counter() > t_end_box[0] + 2:
                break
    except (asyncio.IncompleteReadError, ConnectionError, RuntimeError, asyncio.TimeoutError, OSError, KeyError, IndexError, struct.error) as e:
        if os.environ.get("LOAD_DEBUG"):
            print("client", name, "ended:", repr(e), file=sys.stderr)
        if joined:
            st.dropped += 1
        else:
            st.failed += 1
    finally:
        if mover:
            mover.cancel()
        try:
            w.close()
        except Exception:
            pass


async def worker(ids, a, st, probes):
    t_end_box = [time.perf_counter() + 10 ** 9]
    tasks = []
    start = time.perf_counter()
    for k, i in enumerate(ids):
        moving = (i % 1000) < a.moving * 1000 and i not in probes
        tasks.append(asyncio.ensure_future(one_client(i, a, st, t_end_box, moving, i in probes)))
        if a.ramp > 0 and (k + 1) % max(1, int(a.ramp / a.procs / 10)) == 0:
            await asyncio.sleep(0.1)                   # ramp: a.ramp clients per second over all processes
    # wait until everybody has joined or failed (or the timeout), then run the steady window
    deadline = time.perf_counter() + a.join_timeout
    while st.joined + st.failed < len(ids) and time.perf_counter() < deadline:
        await asyncio.sleep(0.2)
    st.t_steady0 = time.perf_counter()
    t_end_box[0] = time.perf_counter() + a.seconds
    st.steady_start_wall = time.time()
    await asyncio.sleep(a.seconds + 3)
    for t in tasks:
        t.cancel()
    st.steady_s = a.seconds


def proc_main(pid, ids, a, probes, q):
    st = Stats()
    st.t_steady0 = 0
    st.steady_start_wall = 0
    st.steady_s = 0
    f0 = 0
    try:
        asyncio.run(worker(ids, a, st, probes))
    finally:
        q.put({"joined": st.joined, "failed": st.failed, "dropped": st.dropped, "join_ms": st.join_ms, "probe_ms": st.probe_ms, "frames_in": st.frames_in,
               "bytes_in": st.bytes_in, "frames_out": st.frames_out, "steady_start_wall": st.steady_start_wall})


def pct(v, p):
    if not v:
        return None
    v = sorted(v)
    return round(v[min(len(v) - 1, int(p / 100.0 * len(v)))], 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", type=int)
    ap.add_argument("n", type=int)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--moving", type=float, default=0.2)
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--ramp", type=float, default=100)
    ap.add_argument("--hz", type=float, default=20)
    ap.add_argument("--probes", type=int, default=10)
    ap.add_argument("--procs", type=int, default=1)
    ap.add_argument("--prefix", default="L")
    ap.add_argument("--join-timeout", type=float, default=120, dest="join_timeout")
    a = ap.parse_args()
    ids = list(range(a.n))
    probes = set(ids[:: max(1, a.n // max(1, a.probes))][: a.probes])
    q = Queue()
    procs = [Process(target=proc_main, args=(k, ids[k:: a.procs], a, probes, q)) for k in range(a.procs)]
    t0 = time.time()
    for p in procs:
        p.start()
    res = [q.get() for _ in procs]
    for p in procs:
        p.join()
    tot = lambda k: sum(r[k] for r in res)
    join = [x for r in res for x in r["join_ms"]]
    probe = [x for r in res for x in r["probe_ms"]]
    out = {
        "clients": a.n, "joined": tot("joined"), "failed": tot("failed"), "dropped": tot("dropped"), "moving_fraction": a.moving, "hz": a.hz, "procs": a.procs,
        "join_ms_p50": pct(join, 50), "join_ms_p95": pct(join, 95), "join_ms_max": pct(join, 100),
        "probe_ms_p50": pct(probe, 50), "probe_ms_p95": pct(probe, 95), "probe_ms_p99": pct(probe, 99), "probe_samples": len(probe),
        "frames_in": tot("frames_in"), "bytes_in": tot("bytes_in"), "frames_out": tot("frames_out"),
        "steady_start_wall": min(r["steady_start_wall"] for r in res), "steady_seconds": a.seconds, "wall_seconds": round(time.time() - t0, 1),
    }
    print(json.dumps(out))
    print("joined %d/%d, failed %d, dropped %d; join p50/p95 %s/%s ms; probe latency p50/p95/p99 %s/%s/%s ms (%d samples)"
          % (out["joined"], a.n, out["failed"], out["dropped"], out["join_ms_p50"], out["join_ms_p95"], out["probe_ms_p50"], out["probe_ms_p95"], out["probe_ms_p99"], len(probe)), file=sys.stderr)


if __name__ == "__main__":
    main()
