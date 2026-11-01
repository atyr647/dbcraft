#!/usr/bin/env python3
"""Generate the shared benchmark inputs and the oracle (expected) results.

Writes into data/: vals.bin varints.bin frames.bin pos.bin chunk.bin frames_out.bin aes_expected.bin expected.txt
Every implementation (Tcl interpreted, Tcl compiled with tcl-aot, Rust) must print the same RESULT lines as expected.txt.
"""
import os, random, struct, subprocess, sys
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(D, exist_ok=True)
R = random.Random(20261101)

def vi(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80); n >>= 7
    out.append(n)
    return bytes(out)

def vi_dec(buf):
    pos = 0; vals = []
    while pos < len(buf):
        v = 0; sh = 0
        while True:
            b = buf[pos]; pos += 1
            v |= (b & 0x7F) << sh
            if not b & 0x80: break
            sh += 7
        vals.append(v)
    return vals

exp = []

# (a) varints: 1,000,000 values, mostly 1 byte, some 2 and 3 bytes
NV = 1_000_000
vals = []
for _ in range(NV):
    r = R.random()
    vals.append(R.randrange(128) if r < 0.70 else R.randrange(128, 16384) if r < 0.95 else R.randrange(16384, 2_097_152))
open(f"{D}/vals.bin", "wb").write(struct.pack(f"<{NV}I", *vals))
enc = b"".join(vi(v) for v in vals)
open(f"{D}/varints.bin", "wb").write(enc)
exp.append(f"RESULT vi_decode count={NV} sum={sum(vals)}")
exp.append(f"RESULT vi_encode len={len(enc)} ok=1")

# (b) frames: 200,000 x (len varint, id varint, body)
NF = 200_000
ids = [0x1C, 0x1D, 0x06, 0x1B, 0x2F, 0x15, 0x3A, 0x7F, 0x80 + 5, 0x1C0]
fr = bytearray(); idsum = 0; bb = 0
for _ in range(NF):
    pid = R.choice(ids)
    bl = R.randrange(200, 1000) if R.random() < 0.01 else R.randrange(8, 61)
    body = R.randbytes(bl)
    p = vi(pid) + body
    fr += vi(len(p)) + p
    idsum += pid; bb += bl
open(f"{D}/frames.bin", "wb").write(bytes(fr))
exp.append(f"RESULT split_scan frames={NF} idsum={idsum} bodybytes={bb}")
exp.append(f"RESULT split_index frames={NF} idsum={idsum} bodybytes={bb}")

# (c) 1000 position payloads: 3 doubles, 2 floats, flags (33 bytes, big-endian)
NP = 1000; ITER = 200_000
pls = []
for i in range(NP):
    pls.append((R.uniform(-3e4, 3e4), R.uniform(-64, 320), R.uniform(-3e4, 3e4),
                struct.unpack(">f", struct.pack(">f", R.uniform(-180, 180)))[0],
                struct.unpack(">f", struct.pack(">f", R.uniform(-90, 90)))[0], R.randrange(256)))
open(f"{D}/pos.bin", "wb").write(b"".join(struct.pack(">dddffB", *p) for p in pls))
sx = 0.0; sf = 0
for i in range(ITER):
    x, y, z, yaw, pitch, fl = pls[i % NP]
    sx = sx + x + z + yaw + pitch
    sf += fl
exp.append(f"RESULT pos_decode sx={sx:.6f} flags={sf}")

# (d) build 200,000 outgoing frames
out = bytearray()
for i in range(ITER):
    body = struct.pack(">IdddBB", i, i * 0.5, 64.0, i * 0.25, i & 255, (i >> 3) & 255)
    pid = vi(0x2F + (i & 3))
    out += vi(len(pid) + len(body)) + pid + body
open(f"{D}/frames_out.bin", "wb").write(bytes(out))
exp.append(f"RESULT build_frames len={len(out)} ok=1")

# (e) 2000 connection state machines x 100 rounds
NC, NR = 2000, 100
kinds = [0x1C, 0x1D, 0x06, 0x1B]
mv = ch = ot = by = 0
for c in range(NC):
    for r in range(NR):
        ln = 10 + ((c * 7 + r * 13) % 40)
        by += ln
        if r < 3: continue
        k = kinds[(c + r) & 3]
        if k in (0x1C, 0x1D): mv += 1
        elif k == 6: ch += 1
        else: ot += 1
exp.append(f"RESULT coro moves={mv} chats={ch} other={ot} bytes={by}")

# (f) 1 MiB chunk-like data: layered terrain palette indices, mostly runs, some noise
chunk = bytearray()
for s in range(256):
    for i in range(4096):
        y = i >> 8
        v = 0 if y > 11 else (1 if y > 3 else (2 if y > 0 else 3))
        if R.random() < 0.04: v = R.randrange(4, 24)
        chunk.append(v)
open(f"{D}/chunk.bin", "wb").write(bytes(chunk))
key = bytes(range(16)); iv = bytes(range(0x10, 0x20))
open(f"{D}/chunk.bin.in", "wb").write(bytes(chunk))
r = subprocess.run(["openssl", "enc", "-aes-128-cfb8", "-K", key.hex(), "-iv", iv.hex(), "-in", f"{D}/chunk.bin", "-out", f"{D}/aes_expected.bin"], capture_output=True)
if r.returncode: sys.exit(r.stderr.decode())
os.remove(f"{D}/chunk.bin.in")
a = open(f"{D}/aes_expected.bin", "rb").read()
exp.append(f"RESULT aes_cfb8 len={len(a)} ok=1")
exp.append(f"RESULT z_roundtrip ok=1")
open(f"{D}/expected.txt", "w").write("\n".join(exp) + "\n")
print("\n".join(exp))
