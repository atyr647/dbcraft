"""Anvil (region file) and NBT reading/writing with the Python standard library only.

NBT values keep their tag type so a chunk can be written back exactly:
  Byte/Short/Long/Float are int/float subclasses, Python int is TAG_Int, float is TAG_Double, str is TAG_String, dict is a compound (insertion order kept),
  ListTag (a list with .etype), ByteArray (bytes), IntArray (list of int), LongArray (list of signed 64-bit ints).
Region files: 4 KiB sectors, 1024 offset entries (3 bytes sector number, 1 byte sector count) and 1024 timestamps, each chunk is
[4-byte length][1-byte compression: 1 gzip, 2 zlib, 3 none, 4 lz4 (lz4-java block stream), +128 = body in c.X.Z.mcc][data].
Read the formats from the 26.3 classes (RegionFileVersion, SerializableChunkData); nothing here is copied from Mojang code.
"""
import gzip, os, struct, time, zlib

TAG_END, TAG_BYTE, TAG_SHORT, TAG_INT, TAG_LONG, TAG_FLOAT, TAG_DOUBLE, TAG_BYTE_ARRAY, TAG_STRING, TAG_LIST, TAG_COMPOUND, TAG_INT_ARRAY, TAG_LONG_ARRAY = range(13)


class Byte(int): pass
class Short(int): pass
class Long(int): pass
class Float(float): pass
class ByteArray(bytes): pass
class IntArray(list): pass
class LongArray(list): pass


class ListTag(list):
    def __init__(self, items=(), etype=TAG_END):
        super().__init__(items)
        self.etype = etype


class NbtError(ValueError):
    pass


# ---------------------------------------------------------------------------------------------------------------- reading
def _read(buf, o, t):
    if t == TAG_BYTE:
        return Byte(struct.unpack_from(">b", buf, o)[0]), o + 1
    if t == TAG_SHORT:
        return Short(struct.unpack_from(">h", buf, o)[0]), o + 2
    if t == TAG_INT:
        return struct.unpack_from(">i", buf, o)[0], o + 4
    if t == TAG_LONG:
        return Long(struct.unpack_from(">q", buf, o)[0]), o + 8
    if t == TAG_FLOAT:
        return Float(struct.unpack_from(">f", buf, o)[0]), o + 4
    if t == TAG_DOUBLE:
        return struct.unpack_from(">d", buf, o)[0], o + 8
    if t == TAG_BYTE_ARRAY:
        n = struct.unpack_from(">i", buf, o)[0]
        if n < 0 or o + 4 + n > len(buf):
            raise NbtError("byte array length out of range")
        return ByteArray(buf[o + 4:o + 4 + n]), o + 4 + n
    if t == TAG_STRING:
        n = struct.unpack_from(">H", buf, o)[0]
        if o + 2 + n > len(buf):
            raise NbtError("string length out of range")
        return buf[o + 2:o + 2 + n].decode("utf-8", "surrogatepass") if n else "", o + 2 + n
    if t == TAG_LIST:
        et = buf[o]
        n = struct.unpack_from(">i", buf, o + 1)[0]
        o += 5
        if n < 0 or (n and et == TAG_END):
            raise NbtError("bad list header")
        out = ListTag(etype=et)
        if et in (TAG_BYTE, TAG_SHORT, TAG_INT, TAG_LONG, TAG_FLOAT, TAG_DOUBLE) and n > 16:       # fast path for big numeric lists
            size = {TAG_BYTE: 1, TAG_SHORT: 2, TAG_INT: 4, TAG_LONG: 8, TAG_FLOAT: 4, TAG_DOUBLE: 8}[et]
            fmt = ">" + str(n) + {TAG_BYTE: "b", TAG_SHORT: "h", TAG_INT: "i", TAG_LONG: "q", TAG_FLOAT: "f", TAG_DOUBLE: "d"}[et]
            vals = struct.unpack_from(fmt, buf, o)
            cls = {TAG_BYTE: Byte, TAG_SHORT: Short, TAG_LONG: Long, TAG_FLOAT: Float}.get(et)
            out.extend(cls(v) for v in vals) if cls else out.extend(vals)
            return out, o + n * size
        for _ in range(n):
            v, o = _read(buf, o, et)
            out.append(v)
        return out, o
    if t == TAG_COMPOUND:
        out = {}
        while True:
            ct = buf[o]
            o += 1
            if ct == TAG_END:
                return out, o
            nl = struct.unpack_from(">H", buf, o)[0]
            name = buf[o + 2:o + 2 + nl].decode("utf-8", "surrogatepass")
            v, o = _read(buf, o + 2 + nl, ct)
            out[name] = v
    if t == TAG_INT_ARRAY:
        n = struct.unpack_from(">i", buf, o)[0]
        if n < 0 or o + 4 + 4 * n > len(buf):
            raise NbtError("int array length out of range")
        return IntArray(struct.unpack_from(">%di" % n, buf, o + 4)), o + 4 + 4 * n
    if t == TAG_LONG_ARRAY:
        n = struct.unpack_from(">i", buf, o)[0]
        if n < 0 or o + 4 + 8 * n > len(buf):
            raise NbtError("long array length out of range")
        return LongArray(struct.unpack_from(">%dq" % n, buf, o + 4)), o + 4 + 8 * n
    raise NbtError("unknown tag type %d" % t)


def parse_nbt(buf, network=False):
    """-> (root name, root value).  network=True: no root name (the form used inside packets)."""
    t = buf[0]
    if t != TAG_COMPOUND:
        raise NbtError("root is not a compound")
    if network:
        v, _ = _read(buf, 1, TAG_COMPOUND)
        return "", v
    nl = struct.unpack_from(">H", buf, 1)[0]
    name = buf[3:3 + nl].decode("utf-8", "surrogatepass")
    v, _ = _read(buf, 3 + nl, TAG_COMPOUND)
    return name, v


# ---------------------------------------------------------------------------------------------------------------- writing
def tag_type(v):
    if isinstance(v, Byte): return TAG_BYTE
    if isinstance(v, Short): return TAG_SHORT
    if isinstance(v, Long): return TAG_LONG
    if isinstance(v, Float): return TAG_FLOAT
    if isinstance(v, bool): return TAG_BYTE
    if isinstance(v, int): return TAG_INT
    if isinstance(v, float): return TAG_DOUBLE
    if isinstance(v, str): return TAG_STRING
    if isinstance(v, ByteArray): return TAG_BYTE_ARRAY
    if isinstance(v, IntArray): return TAG_INT_ARRAY
    if isinstance(v, LongArray): return TAG_LONG_ARRAY
    if isinstance(v, ListTag): return TAG_LIST
    if isinstance(v, dict): return TAG_COMPOUND
    raise NbtError("cannot infer the tag type of %r" % type(v))


def _mutf8(s):
    return s.encode("utf-8", "surrogatepass")


def _write(out, v, t):
    if t == TAG_BYTE: out += struct.pack(">b", int(v))
    elif t == TAG_SHORT: out += struct.pack(">h", int(v))
    elif t == TAG_INT: out += struct.pack(">i", int(v))
    elif t == TAG_LONG: out += struct.pack(">q", int(v))
    elif t == TAG_FLOAT: out += struct.pack(">f", float(v))
    elif t == TAG_DOUBLE: out += struct.pack(">d", float(v))
    elif t == TAG_BYTE_ARRAY: out += struct.pack(">i", len(v)) + bytes(v)
    elif t == TAG_STRING:
        b = _mutf8(v)
        out += struct.pack(">H", len(b)) + b
    elif t == TAG_LIST:
        et = v.etype if isinstance(v, ListTag) and (len(v) == 0 or v.etype != TAG_END) else (tag_type(v[0]) if len(v) else TAG_END)
        out += struct.pack(">bi", et, len(v))
        if et in (TAG_LONG, TAG_INT, TAG_SHORT, TAG_BYTE, TAG_FLOAT, TAG_DOUBLE) and len(v) > 16:
            fmt = {TAG_BYTE: "b", TAG_SHORT: "h", TAG_INT: "i", TAG_LONG: "q", TAG_FLOAT: "f", TAG_DOUBLE: "d"}[et]
            out += struct.pack(">%d%s" % (len(v), fmt), *v)
        else:
            for x in v:
                _write(out, x, et)
    elif t == TAG_COMPOUND:
        for k, x in v.items():
            xt = tag_type(x)
            b = _mutf8(k)
            out += struct.pack(">bH", xt, len(b)) + b
            _write(out, x, xt)
        out.append(TAG_END)
    elif t == TAG_INT_ARRAY: out += struct.pack(">i", len(v)) + struct.pack(">%di" % len(v), *v)
    elif t == TAG_LONG_ARRAY: out += struct.pack(">i", len(v)) + struct.pack(">%dq" % len(v), *v)
    else:
        raise NbtError("cannot write tag type %d" % t)


def write_nbt(value, name="", network=False):
    out = bytearray([TAG_COMPOUND])
    if not network:
        b = _mutf8(name)
        out += struct.pack(">H", len(b)) + b
    _write(out, value, TAG_COMPOUND)
    return bytes(out)


# ---------------------------------------------------------------------------------------------------------------- LZ4 (lz4-java block stream)
def lz4_block_decompress(src, dst_len):
    """Plain LZ4 block decoder."""
    out = bytearray()
    i, n = 0, len(src)
    while i < n:
        tok = src[i]
        i += 1
        ll = tok >> 4
        if ll == 15:
            while True:
                b = src[i]
                i += 1
                ll += b
                if b != 255:
                    break
        out += src[i:i + ll]
        i += ll
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        if off == 0 or off > len(out):
            raise NbtError("bad LZ4 offset")
        ml = tok & 15
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        start = len(out) - off
        if off >= ml:
            out += out[start:start + ml]
        else:
            for k in range(ml):
                out.append(out[start + k])
    if len(out) != dst_len:
        raise NbtError("LZ4 block length mismatch")
    return bytes(out)


def lz4_stream_decompress(data):
    """lz4-java LZ4BlockOutputStream format: repeated [magic 'LZ4Block'][token][compressed len LE][raw len LE][xxhash LE][data]."""
    out = bytearray()
    o = 0
    while o < len(data):
        if data[o:o + 8] != b"LZ4Block":
            raise NbtError("bad LZ4 block magic")
        token = data[o + 8]
        clen, dlen = struct.unpack_from("<ii", data, o + 9)
        o += 21
        body = data[o:o + clen]
        o += clen
        method = token & 0xF0
        if method == 0x10:        # stored
            out += body
        elif method == 0x20:
            out += lz4_block_decompress(body, dlen)
        else:
            raise NbtError("unknown LZ4 block method")
        if dlen == 0 and clen == 0:
            break
    return bytes(out)


# ---------------------------------------------------------------------------------------------------------------- region files
SECTOR = 4096


def _decompress(ctype, body):
    if ctype == 2: return zlib.decompress(body)
    if ctype == 1: return gzip.decompress(body)
    if ctype == 3: return body
    if ctype == 4: return lz4_stream_decompress(body)
    raise NbtError("unsupported region compression %d" % ctype)


def read_region(path):
    """Yield (chunk_x, chunk_z, nbt_bytes) for every chunk stored in an r.X.Z.mca file (coordinates are absolute chunk coordinates)."""
    base = os.path.basename(path)
    parts = base.split(".")
    rx, rz = int(parts[1]), int(parts[2])
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 2 * SECTOR:
        return
    for i in range(1024):
        ent = struct.unpack_from(">I", data, i * 4)[0]
        sector, count = ent >> 8, ent & 255
        if ent == 0 or sector < 2:
            continue
        off = sector * SECTOR
        if off + 5 > len(data):
            continue
        length = struct.unpack_from(">I", data, off)[0]
        ctype = data[off + 4]
        cx = rx * 32 + (i & 31)
        cz = rz * 32 + (i >> 5)
        if ctype & 128:
            ext = os.path.join(os.path.dirname(path), "c.%d.%d.mcc" % (cx, cz))
            if not os.path.exists(ext):
                continue
            with open(ext, "rb") as g:
                body = g.read()
            ctype &= 127
        else:
            if length < 1 or off + 4 + length > len(data):
                continue
            body = data[off + 5:off + 4 + length]
        yield cx, cz, _decompress(ctype, body)


def region_files(folder):
    out = []
    for n in sorted(os.listdir(folder)):
        if n.startswith("r.") and n.endswith(".mca"):
            out.append(os.path.join(folder, n))
    return out


def write_region(path, chunks, timestamp=None):
    """chunks: {(chunk_x, chunk_z): nbt_bytes} for ONE region (r.X.Z). Writes zlib-compressed chunks; a chunk of 1 MiB or more would need a .mcc file (not supported: raises)."""
    ts = int(timestamp if timestamp is not None else time.time())
    header = bytearray(2 * SECTOR)
    body = bytearray()
    sector = 2
    for (cx, cz), nbt in sorted(chunks.items(), key=lambda kv: ((kv[0][1] & 31) << 5) | (kv[0][0] & 31)):
        comp = zlib.compress(nbt, 6)
        rec = struct.pack(">IB", len(comp) + 1, 2) + comp
        pad = (-len(rec)) % SECTOR
        rec += b"\0" * pad
        count = len(rec) // SECTOR
        if count > 255:
            raise NbtError("chunk too large for an in-file region entry (%d bytes)" % len(rec))
        idx = ((cz & 31) << 5) | (cx & 31)
        struct.pack_into(">I", header, idx * 4, (sector << 8) | count)
        struct.pack_into(">I", header, SECTOR + idx * 4, ts)
        body += rec
        sector += count
    with open(path, "wb") as f:
        f.write(header)
        f.write(body)
