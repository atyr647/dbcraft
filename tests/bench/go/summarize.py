#!/usr/bin/env python3
"""Merge Go (this directory's out/go.N.log, GOMAXPROCS=1), Rust and Tcl (tests/bench/tcl/out logs) into comparison tables.
usage: summarize.py [GO_OUT_DIR] [TCL_OUT_DIR]"""
import glob, re, sys, os
here = os.path.dirname(os.path.abspath(__file__))
gout = sys.argv[1] if len(sys.argv) > 1 else f"{here}/out"
tout = sys.argv[2] if len(sys.argv) > 2 else f"{here}/../tcl/out"
def load(pattern):
    best, units, nb = {}, {}, {}
    for f in sorted(glob.glob(pattern)):
        for l in open(f):
            if l.startswith("BENCH "):
                _, n, s, u, b = l.split(); s = float(s)
                if n not in best or s < best[n]: best[n] = s
                units[n] = int(u); nb[n] = int(b)
    return best, units, nb
M = {"go": load(f"{gout}/go.[0-9].log"), "interp": load(f"{tout}/interp.*.log"), "aot": load(f"{tout}/aot.*.log"), "rust": load(f"{tout}/rust.*.log")}
def rate(m, n):
    best, units, nb = M[m]
    if n not in best: return None
    return units[n] / best[n], (nb[n] / best[n] / 1e6 if nb[n] else None)
def fmt(r, bytes_only=False):
    if r is None: return "-"
    ops, mb = r
    if bytes_only: return f"{mb:,.0f} MB/s" if mb >= 10 else f"{mb:.1f} MB/s" if mb >= 1 else f"{mb*1000:.1f} kB/s"
    o = f"{ops/1e6:.1f} M/s" if ops >= 1e6 else f"{ops/1e3:.0f} k/s"
    return o + (f" ({mb:,.0f} MB/s)" if mb else "")
rows = [("VarInt decode (1M)", "vi_decode"), ("VarInt encode (1M)", "vi_encode"), ("frame split, copy body (200k frames)", "split_index"),
        ("frame split, no copy (Go slice into input)", "split_nocopy"), ("position decode (200k)", "pos_decode"), ("build frames (200k)", "build_frames")]
print("| benchmark | Tcl interp | Tcl + tcl-aot | Go (GOMAXPROCS=1) | Rust | Go / Rust |")
print("|---|---|---|---|---|---|")
for lab, n in rows:
    r = {m: rate(m, n) for m in M}   # no-copy exists only for Go: other columns and the ratio stay "-" (a like-for-like Rust figure was not measured)
    ratio = f"{r['go'][0]/r['rust'][0]:.2f}x" if r["go"] and r["rust"] else "-"
    print(f"| {lab} | {fmt(r['interp'])} | {fmt(r['aot'])} | {fmt(r['go'])} | {fmt(r['rust'])} | {ratio} |")
print()
print("Connection state machines, 2000 conns x 100 packets (200k packet deliveries):\n")
print("| design | packets/s |\n|---|---|")
for lab, m, n in [("Tcl coroutine per connection, interpreter", "interp", "coro"), ("Tcl coroutine per connection, tcl-aot", "aot", "coro"),
                  ("Go goroutine per connection, unbuffered channel (GOMAXPROCS=1)", "go", "coro"), ("Go goroutine per connection, 128-slot channel (GOMAXPROCS=1)", "go", "coro_buf"),
                  ("Go single goroutine, event style (GOMAXPROCS=1)", "go", "coro_event"), ("Rust enum state machine", "rust", "coro")]:
    r = rate(m, n); print(f"| {lab} | {r[0]/1e6:.2f} M/s |")
g4 = load(f"{gout}/go4.[0-9].log")
print("\nSame Go channel designs with GOMAXPROCS=4: " + ", ".join(f"{n} {g4[1][n]/g4[0][n]/1e6:.2f} M/s" for n in ("coro", "coro_buf", "coro_event") if n in g4[0]))
print("\nzlib / AES (one core):\n")
print("| benchmark | Tcl (libz) | Go compress/zlib | Go klauspost | Rust (libz) |\n|---|---|---|---|---|")
for lab, a, b, c, d in [("zlib compress 1 MiB L6", "z_compress", "z_compress", "z_compress_klauspost", "z_compress"),
                        ("zlib decompress 1 MiB", "z_decompress", "z_decompress", "z_decompress_klauspost", "z_decompress"),
                        ("zlib compress 128 KiB L6", None, "z128_compress", "z128_compress_klauspost", None),
                        ("zlib decompress 128 KiB", None, "z128_decompress", "z128_decompress_klauspost", None)]:
    print(f"| {lab} | {fmt(rate('interp', a), True) if a else '-'} | {fmt(rate('go', b), True)} | {fmt(rate('go', c), True)} | {fmt(rate('rust', d), True) if d else '-'} |")
print("\n| AES-128-CFB8, 1 MiB | MB/s |\n|---|---|")
for lab, m, n in [("Tcl pure-Tcl AES (tcllib, tcl-aot, 64 KiB)", "aot", "aes_cfb8"), ("Rust AES-NI encrypt, serial", "rust", "aes_cfb8"), ("Rust AES-NI decrypt, 4 blocks in flight", "rust", "aes_cfb8_dec"),
                  ("Go crypto/aes, one Block.Encrypt per byte, encrypt", "go", "aes_cfb8"), ("Go, encrypt, 4 connection streams interleaved", "go", "aes_cfb8_x4"),
                  ("Go, decrypt", "go", "aes_cfb8_dec")]:
    print(f"| {lab} | {fmt(rate(m, n), True)} |")
# players per core, same assumptions as docs/TCL-EVALUATION.md
def per(m, n, k=1):
    b, u, _ = M[m]; return b[n] / u[n] * k
def bpb(m, n):  # seconds per byte
    b, u, _ = M[m]; return b[n] / u[n]
def base(m, split="split_index"): return 5 * (per(m, split) + per(m, "pos_decode")) + 25 * per(m, "build_frames")
V = []
V.append(("Tcl + tcl-aot, native AES (Rust serial AES-NI + dec rates)", base("aot"), 1000 * bpb("rust", "aes_cfb8") + 150 * bpb("rust", "aes_cfb8_dec")))
V.append(("Rust, AES-NI (serial encrypt)", base("rust"), 1000 * bpb("rust", "aes_cfb8") + 150 * bpb("rust", "aes_cfb8_dec")))
V.append(("Go, copy-body framing, serial AES (same method as Rust row)", base("go"), 1000 * bpb("go", "aes_cfb8") + 150 * bpb("go", "aes_cfb8_dec")))
V.append(("Go, no-copy framing, serial AES", base("go", "split_nocopy"), 1000 * bpb("go", "aes_cfb8") + 150 * bpb("go", "aes_cfb8_dec")))
V.append(("Go, no-copy framing, 4-stream interleaved AES", base("go", "split_nocopy"), 1000 * bpb("go", "aes_cfb8_x4") + 150 * bpb("go", "aes_cfb8_dec")))
print("\nPlayers per core, gateway work only (20 TPS; per player per tick: 5 inbound packets, 25 outbound frames, AES over 1000 B out + 150 B in):\n")
print("| variant | framing + decode | AES-CFB8 | per player-tick | players/core (100%) | players/core (70%) |\n|---|---|---|---|---|---|")
for lab, b, a in V:
    c = b + a; print(f"| {lab} | {b*1e6:.1f} us | {a*1e6:.1f} us | {c*1e6:.1f} us | {0.050/c:,.0f} | {0.035/c:,.0f} |")
