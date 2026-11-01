#!/usr/bin/env python3
"""Compression ratios on the REAL captured vanilla terrain packets, for comparison with the SQL encoder (sql/440).
usage (from the repo root):  python3 tests/bench/world/zlib_baseline.py
Needs /tmp/dbcraft-fixtures/terrain_nocomp.jsonl (tools/capture_vanilla.py against a normal-world server); reads the packets through tools/import_chunk_capture.py.
Reports the total ratio for: zlib levels 1/6/9, zlib's RLE strategy (distance-1 matches only: the same idea as the SQL encoder), Huffman-only, fixed-Huffman+LZ.
"""
import subprocess, sys, zlib, time

out = subprocess.run([sys.executable, "tools/import_chunk_capture.py", "expected"], capture_output=True, text=True, check=True).stdout
packets = []
for line in out.splitlines():
    cx, cz, framed = line.split("\t")
    b = bytes.fromhex(framed)
    o = 0
    while b[o] & 0x80:
        o += 1
    packets.append(b[o + 1:])                      # payload = packet id + body
raw = sum(len(p) for p in packets)
print(f"{len(packets)} real vanilla chunk packets, {raw} bytes (payload)")


def run(name, level, strategy):
    t = time.perf_counter()
    z = 0
    for p in packets:
        c = zlib.compressobj(level, zlib.DEFLATED, 15, 8, strategy)
        z += len(c.compress(p) + c.flush())
    ms = (time.perf_counter() - t) * 1000
    print(f"  {name:34s} {z:9d} bytes  {raw / z:5.2f}x   {ms / len(packets):7.2f} ms per packet")


run("zlib level 1", 1, zlib.Z_DEFAULT_STRATEGY)
run("zlib level 6", 6, zlib.Z_DEFAULT_STRATEGY)
run("zlib level 9", 9, zlib.Z_DEFAULT_STRATEGY)
run("RLE only (distance-1 matches)", 6, zlib.Z_RLE)
run("Huffman only (no matches)", 6, zlib.Z_HUFFMAN_ONLY)
run("fixed Huffman + LZ77", 6, zlib.Z_FIXED)
