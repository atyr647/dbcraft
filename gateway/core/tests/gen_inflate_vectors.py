#!/usr/bin/env python3
"""Generates gateway/core/tests/inflate_vectors.txt: zlib streams made by Python's zlib (real zlib, several levels and strategies) for data that the
Rust test regenerates by the same formulas, so the file holds only the compressed side.  Line format:  kind n seed level strategy hex
Run:  python3 gateway/core/tests/gen_inflate_vectors.py"""
import os, zlib

WORDS = [b"minecraft", b"stone", b"dirt", b"grass_block", b"level_chunk", b"player", b"chat", b" ", b"\n"]

def plain(kind, n, seed):
    if kind == "lcg":
        x, out = seed, bytearray()
        for _ in range(n):
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
            out.append((x >> 16) & 0xFF)
        return bytes(out)
    if kind == "runs":
        return bytes(((i // 37) * 5) & 0xFF for i in range(n))
    if kind == "text":
        x, out = seed, bytearray()
        while len(out) < n:
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
            out += WORDS[(x >> 16) % len(WORDS)]
        return bytes(out[:n])
    raise ValueError(kind)

STRATEGIES = {"default": zlib.Z_DEFAULT_STRATEGY, "filtered": zlib.Z_FILTERED, "huffman": zlib.Z_HUFFMAN_ONLY, "rle": zlib.Z_RLE, "fixed": zlib.Z_FIXED}

lines = []
for kind in ("lcg", "runs", "text"):
    for n in ((0, 1, 100, 5000) if kind == "lcg" else (0, 1, 100, 5000, 70000, 300000)):   # incompressible data stays small (the file is committed)
        for level in (0, 1, 6, 9):
            for sname, strat in STRATEGIES.items():
                if level == 0 and sname != "default":
                    continue
                if n > 5000 and (level == 0 or (n >= 300000 and sname != "default") or (n >= 70000 and sname in ("huffman", "filtered"))):
                    continue                                                      # keep the committed file small
                c = zlib.compressobj(level, zlib.DEFLATED, 15, 8, strat)
                z = c.compress(plain(kind, n, 42)) + c.flush()
                lines.append(f"{kind} {n} 42 {level} {sname} {z.hex()}")
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "inflate_vectors.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")
print(len(lines), "vectors")
