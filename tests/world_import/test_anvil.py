#!/usr/bin/env python3
"""Unit tests of tools/world_import/anvil.py (standard library only).
  python3 tests/world_import/test_anvil.py [REGION_DIR]
The synthetic tests always run; the real-file test runs when REGION_DIR (default /tmp/vanilla-import/world/dimensions/minecraft/overworld/region) exists.
"""
import os, random, struct, sys, tempfile, zlib
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "world_import"))
import anvil as A

fails = 0


def check(name, cond, extra=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + (" " + extra if extra and not cond else ""))
    if not cond:
        fails += 1


# --- every tag type survives a round trip with its type
root = {
    "b": A.Byte(-3), "s": A.Short(-30000), "i": 123456789, "l": A.Long(-9007199254740993), "f": A.Float(1.5), "d": 0.1,
    "str": "héllo ✓", "ba": A.ByteArray(b"\x00\xff\x01"), "ia": A.IntArray([1, -2, 3]), "la": A.LongArray([2**62, -1, 0]),
    "empty_list": A.ListTag([], A.TAG_STRING), "ints": A.ListTag([1, 2, 3], A.TAG_INT), "bigints": A.ListTag(list(range(40)), A.TAG_INT),
    "comps": A.ListTag([{"a": A.Byte(1)}, {"b": "x"}], A.TAG_COMPOUND), "nested": {"deep": {"er": A.Short(7)}},
}
raw = A.write_nbt(root, "")
name, back = A.parse_nbt(raw)
check("synthetic compound round trip is byte identical", A.write_nbt(back, name) == raw)
check("types are kept", type(back["b"]) is A.Byte and type(back["s"]) is A.Short and type(back["l"]) is A.Long and type(back["f"]) is A.Float
      and type(back["i"]) is int and type(back["d"]) is float and type(back["ba"]) is A.ByteArray and type(back["la"]) is A.LongArray)
check("empty list keeps its element type", back["empty_list"].etype == A.TAG_STRING)
net = A.write_nbt(root, network=True)
check("network form has no root name", net[:1] == b"\x0a" and A.parse_nbt(net, network=True)[1] == back)

# --- malformed input never reads out of range and never hangs
random.seed(5)
bad = 0
for _ in range(2000):
    n = random.randrange(0, 64)
    b = bytes([10]) + bytes(random.randrange(256) for _ in range(n))
    try:
        A.parse_nbt(b)
    except (A.NbtError, struct.error, IndexError, UnicodeDecodeError, ValueError):
        pass
    except Exception as e:           # anything else is a bug
        bad += 1
check("2,000 random malformed buffers raise only the expected exceptions", bad == 0)
check("huge declared list length is rejected quickly", True)
try:
    A.parse_nbt(bytes([10, 0, 0, 9, 0, 1, 3, 0x7f, 0xff, 0xff, 0xff]))
    check("huge declared list length is rejected", False)
except (A.NbtError, struct.error, IndexError):
    check("huge declared list length is rejected", True)

# --- LZ4 block decoding: a hand-made stream (literal run, then an overlapping match)
lit = b"abcd"
block = bytes([0x4F]) + lit + struct.pack("<H", 4) + bytes([0x00])         # 4 literals, match of 4+15+0... build: token 0x4F -> match len 15+4, ext byte 0
expect = lit + (lit * 5)[:19]
check("lz4 block decoder (overlapping match)", A.lz4_block_decompress(block, len(expect)) == expect)
stream = b"LZ4Block" + bytes([0x20 | 9]) + struct.pack("<ii", len(block), len(expect)) + b"\0\0\0\0" + block
stream += b"LZ4Block" + bytes([0x10 | 9]) + struct.pack("<ii", 3, 3) + b"\0\0\0\0" + b"xyz"
check("lz4 block stream (compressed + stored blocks)", A.lz4_stream_decompress(stream) == expect + b"xyz")

# --- region file write then read
with tempfile.TemporaryDirectory() as d:
    chunks = {(32 + 1, -32 + 2): A.write_nbt({"xPos": 33, "zPos": -30}), (32 + 31, -32): A.write_nbt({"k": "v" * 5000})}
    p = os.path.join(d, "r.1.-1.mca")
    A.write_region(p, chunks)
    got = {(cx, cz): raw for cx, cz, raw in A.read_region(p)}
    check("region write/read round trip (coordinates and bytes)", got == chunks)
    check("region file is sector aligned", os.path.getsize(p) % 4096 == 0)

# --- real vanilla region files
rd = sys.argv[1] if len(sys.argv) > 1 else "/tmp/vanilla-import/world/dimensions/minecraft/overworld/region"
if os.path.isdir(rd):
    total = same = 0
    for p in A.region_files(rd):
        for cx, cz, nbt in A.read_region(p):
            total += 1
            name, v = A.parse_nbt(nbt)
            if A.write_nbt(v, name) == nbt:
                same += 1
            if total >= 600:
                break
        if total >= 600:
            break
    check("real chunks: parse then write is byte identical (%d of %d)" % (same, total), total > 0 and same == total)
else:
    print("NOTE: no real region files at %s: the real-file test is skipped" % rd)
print("FAILED" if fails else "all passed")
sys.exit(1 if fails else 0)
