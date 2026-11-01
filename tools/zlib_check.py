#!/usr/bin/env python3
"""Check zlib streams produced by SQL against a real inflater.

Reads tab-separated lines from standard input:   label <TAB> kind <TAB> hex_stream <TAB> hex_expected
  kind 'zlib'  hex_stream is a zlib stream; it must inflate to hex_expected (and the Adler-32 trailer must be right: zlib checks it).
  kind 'frame' hex_stream is a Minecraft compressed-packet frame  [VarInt packet length][VarInt data length][zlib stream];
               the lengths must be consistent and the stream must inflate to hex_expected (packet id + body), data length bytes long.
Writes one line per input to standard output:   label <TAB> ok | FAIL reason
Standard library only.  Used by tests/sql/280_world_deflate.sql.
"""
import sys, zlib


def varint(b, o=0):
    v = shift = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << shift
        if not c & 0x80:
            return v, o
        shift += 7


for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    label, kind, hs, he = line.split("\t")
    try:
        stream, want = bytes.fromhex(hs), bytes.fromhex(he)
        if kind == "frame":
            plen, o = varint(stream)
            if plen != len(stream) - o:
                print(f"{label}\tFAIL packet length {plen} but {len(stream) - o} bytes follow"); continue
            dlen, o2 = varint(stream, o)
            z = stream[o2:]
            if dlen != len(want):
                print(f"{label}\tFAIL data length {dlen}, payload is {len(want)} bytes"); continue
        else:
            z = stream
        d = zlib.decompressobj(-15 if kind == "raw" else 15)    # kind 'raw': a bare deflate stream (no zlib header or checksum)
        got = d.decompress(z)
        if not d.eof:
            print(f"{label}\tFAIL stream not terminated"); continue
        if d.unused_data:
            print(f"{label}\tFAIL {len(d.unused_data)} bytes after the end of the stream"); continue
        print(f"{label}\tok" if got == want else f"{label}\tFAIL inflates to {len(got)} bytes, expected {len(want)}")
    except Exception as e:  # zlib.error: bad block, bad checksum, ...
        print(f"{label}\tFAIL {type(e).__name__}: {e}")
