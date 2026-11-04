#!/usr/bin/env python3
"""A client that sits in the configuration state for longer than the gateway's 30 s read timeout and keeps its connection alive only by answering the server's keep-alives
(docs/PERF-CAPACITY.md, "The dropped clients").  Before sql/980 the server sent nothing in that state and the gateway closed the silent connection ("read timeout (no bytes)")
after 30 s: this is what a joiner held back by the join entry budget in a 500-player login looked like.  Now the database sends a keep_alive after 15 s and every 15 s after
the answer; the client answers, stays connected, and when it finally sends finish_configuration it enters play.

    tests/gateway/config_keepalive.py --port PORT [--wait 40] [--name NAME]      against a running gateway (any: the PL/Python one answers the same)

Exit code 0 = the connection survived the wait with keep-alives (at least two), and the play state was entered afterwards.  Needs DBCRAFT_REPORTS (packets.json), like the load generator.
"""
import argparse, os, socket, struct, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
import loadgen as L


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=float, default=40.0, help="seconds to stay in the configuration state (more than the gateway's 30 s read timeout)")
    ap.add_argument("--name", default="Idler")
    a = ap.parse_args()
    s = socket.create_connection((a.host, a.port))
    s.settimeout(0.5)
    hs = L.varint(L.SB[("handshake", "minecraft:intention")]) + L.varint(777) + L.string("127.0.0.1") + struct.pack(">H", a.port) + L.varint(2)
    s.sendall(L.varint(len(hs)) + hs + L.frame("login", "minecraft:hello", L.string(a.name) + L.offline_uuid(a.name)))
    state, buf = "login", bytearray()
    t_cfg = None
    keepalives = []
    entered_play = False
    sent_finish = False
    closed = None
    t0 = time.time()
    while True:
        try:
            d = s.recv(65536)
            if not d:
                closed = "closed by the server after %.1f s" % (time.time() - t0)
                break
            buf += d
        except socket.timeout:
            pass
        except OSError as e:
            closed = "error %r after %.1f s" % (e, time.time() - t0)
            break
        while True:
            ln, p = L.read_varint(buf, 0)
            if ln is None or len(buf) - p < ln:
                break
            frame = bytes(buf[p:p + ln])
            del buf[:p + ln]
            pid, o = L.read_varint(frame, 0)
            name = L.CB[state].get(pid, "?")
            body = frame[o:]
            if state == "login" and name == "minecraft:login_finished":
                s.sendall(L.frame("login", "minecraft:login_acknowledged"))
                state = "configuration"
                t_cfg = time.time()
            elif state == "configuration" and name == "minecraft:select_known_packs":
                s.sendall(L.frame("configuration", "minecraft:select_known_packs", L.varint(0)))
            elif state == "configuration" and name == "minecraft:keep_alive":
                keepalives.append(time.time() - t_cfg)
                s.sendall(L.frame("configuration", "minecraft:keep_alive", body))
            elif state == "configuration" and name == "minecraft:ping":
                s.sendall(L.frame("configuration", "minecraft:pong", body))
            elif state == "play" and name == "minecraft:login":
                entered_play = True
        if entered_play:
            break
        if state == "configuration" and t_cfg is not None and not sent_finish and time.time() - t_cfg >= a.wait:
            s.sendall(L.frame("configuration", "minecraft:finish_configuration"))
            state = "play"
            sent_finish = True
        if time.time() - t0 > a.wait + 60:
            closed = "no play packet within %.0f s of the end of the wait" % 60
            break
    ok = closed is None and entered_play and len(keepalives) >= 2
    print("keep-alives answered in the configuration state at (s): %s" % ", ".join("%.1f" % k for k in keepalives))
    print("entered play: %s; connection: %s" % (entered_play, closed or "open"))
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
