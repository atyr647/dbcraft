#!/usr/bin/env python3
"""2000 closed-loop clients: send a batch of 20 position frames (35 bytes each), wait for the 1-byte ack, repeat until the server closes."""
import asyncio, os, struct, sys
PORT = int(os.environ.get("PORT", 25599)); N = int(os.environ.get("NCONN", 2000))
frame = bytes([34, 0x1C]) + struct.pack(">dddffB", 1.5, 64.0, -2.5, 90.0, 0.0, 1)   # length 34 = id + 33-byte body
batch = frame * 20
sent = 0
async def one(i):
    global sent
    for attempt in range(50):
        try:
            r, w = await asyncio.open_connection("127.0.0.1", PORT); break
        except OSError:
            await asyncio.sleep(0.1)
    else:
        return
    try:
        while True:
            w.write(batch); await w.drain()
            await r.readexactly(1); sent += 20
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
async def main():
    await asyncio.gather(*(one(i) for i in range(N)))
asyncio.run(main())
print(f"client frames acked: {sent}")
