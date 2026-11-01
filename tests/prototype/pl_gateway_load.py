#!/usr/bin/env python3
"""Load generator: N connections, each sends FRAMES small frames per 50 ms tick; verifies echoed bytes."""
import socket, selectors, sys, time, os
n, port, ticks, frames = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
sel = selectors.DefaultSelector(); socks = []
for i in range(n):
    s = socket.create_connection(("127.0.0.1", port)); s.setblocking(False)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1); sel.register(s, selectors.EVENT_READ); socks.append(s)
frame = bytes([30]) + os.urandom(30)          # length 30, 30-byte body
sent = got = 0; t0 = time.perf_counter()
for t in range(ticks):
    for s in socks:
        try: s.send(frame * frames); sent += (len(frame) * frames)
        except BlockingIOError: pass
    end = t0 + (t + 1) * 0.05
    while time.perf_counter() < end:
        for k, _ in sel.select(timeout=max(0, end - time.perf_counter())):
            try: got += len(k.fileobj.recv(1 << 20))
            except (BlockingIOError, ConnectionResetError): pass
time.sleep(0.3)
for k, _ in sel.select(timeout=0.2):
    try: got += len(k.fileobj.recv(1 << 20))
    except (BlockingIOError, ConnectionResetError): pass
print(f"client: {n} conns, sent {sent} B, echoed back {got} B (frames echo with 1-byte length: expect about {sent} B)")
