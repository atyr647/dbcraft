"""Shared helpers for reading vanilla captures (tools/capture_vanilla.py output) and the generator reports.  Standard library only.
Captures contain Mojang data and stay outside git; these helpers only read them."""
import json, os, struct

DEFAULT_REPORTS = os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")


def capture_dirs():
    """Where recordings are looked for, in order: $DBCRAFT_CAPTURES, $DBCRAFT_HOME/captures (what tools/bootstrap.sh fills), tests/fixtures/captured in the repository."""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    home = os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft"))
    return [d for d in (os.environ.get("DBCRAFT_CAPTURES", ""), os.path.join(home, "captures"), os.path.join(here, "tests/fixtures/captured")) if d]


def find_capture(name):
    """Path of the recording NAME.jsonl in the first directory that has it, or None."""
    return next((os.path.join(d, name + ".jsonl") for d in capture_dirs() if os.path.exists(os.path.join(d, name + ".jsonl"))), None)


def vi(b, o):
    """Read a VarInt at offset o; returns (value, next offset)."""
    v = s = 0
    while True:
        c = b[o]; o += 1
        v |= (c & 127) << s
        if c < 128:
            return v, o
        s += 7


def skip_nbt(b, o, t):
    """Skip one NBT payload of tag type t (network NBT: the root compound has no name)."""
    fixed = {1: 1, 2: 2, 3: 4, 4: 8, 5: 4, 6: 8}
    if t in fixed: return o + fixed[t]
    if t == 7: return o + 4 + struct.unpack(">i", b[o:o + 4])[0]
    if t == 8: return o + 2 + struct.unpack(">H", b[o:o + 2])[0]
    if t == 9:
        et = b[o]; n = struct.unpack(">i", b[o + 1:o + 5])[0]; o += 5
        for _ in range(n): o = skip_nbt(b, o, et)
        return o
    if t == 10:
        while b[o] != 0:
            nt = b[o]; nl = struct.unpack(">H", b[o + 1:o + 3])[0]; o += 3 + nl; o = skip_nbt(b, o, nt)
        return o + 1
    if t == 11: return o + 4 + 4 * struct.unpack(">i", b[o:o + 4])[0]
    if t == 12: return o + 4 + 8 * struct.unpack(">i", b[o:o + 4])[0]
    raise ValueError(f"nbt tag {t}")


def packets(path, name, direction="clientbound"):
    """Yield (record, raw bytes) for every captured packet with this name."""
    for line in open(path):
        r = json.loads(line)
        if r["name"] == name and r["dir"] == direction:
            yield r, bytes.fromhex(r["hex"])


def registry_names(path):
    """{registry id: [entry keys in id order]} from the configuration-phase registry_data packets."""
    out = {}
    for _, b in packets(path, "minecraft:registry_data"):
        _, o = vi(b, 0); _, o = vi(b, o)
        ln, o = vi(b, o); reg = b[o:o + ln].decode(); o += ln
        n, o = vi(b, o); names = []
        for _ in range(n):
            l2, o = vi(b, o); names.append(b[o:o + l2].decode()); o += l2
            has = b[o]; o += 1
            if has:
                o = skip_nbt(b, o + 1, b[o])           # the root tag byte says the type (usually a compound, not always)
        out[reg] = names
    return out


def state_names(report_dir=None):
    """{block state id: 'minecraft:oak_log[axis=y]'} from blocks.json, spelled exactly like ref.block_state.name."""
    blocks = json.load(open(os.path.join(report_dir or os.environ.get("DBCRAFT_REPORTS", DEFAULT_REPORTS), "blocks.json")))
    out = {}
    for bname, b in blocks.items():
        for s in b["states"]:
            sp = s.get("properties", {})
            out[s["id"]] = bname + ("[" + ",".join(f"{k}={v}" for k, v in sp.items()) + "]" if sp else "")
    return out


def unpack(data, bits, n):
    """Vanilla SimpleBitStorage: floor(64/bits) entries per big-endian long, LSB first, no entry spans two longs."""
    if bits == 0:
        return [0] * n
    per = 64 // bits
    out = []
    for i in range(n):
        w = int.from_bytes(data[(i // per) * 8:(i // per) * 8 + 8], "big")
        out.append((w >> ((i % per) * bits)) & ((1 << bits) - 1))
    return out


def container(b, o, entries, biome):
    """Parse a paletted container: returns (bits, palette ids or None for the global palette, data bytes, next offset)."""
    bits = b[o]; o += 1
    if bits == 0:
        v, o = vi(b, o)
        return 0, [v], b"", o
    pal = None
    if bits <= (3 if biome else 8):
        n, o = vi(b, o); pal = []
        for _ in range(n):
            v, o = vi(b, o); pal.append(v)
    per = 64 // bits
    ln = ((entries + per - 1) // per) * 8
    return bits, pal, b[o:o + ln], o + ln


def bitset(b, o):
    """Protocol BitSet: VarInt byte count, little-endian bytes."""
    n, o = vi(b, o)
    v = int.from_bytes(b[o:o + n], "little")
    return [i for i in range(n * 8) if v >> i & 1], o + n


def parse_chunk(b):
    """Decode a framed minecraft:level_chunk_with_light packet into a dict.  Offsets of the heightmap entries are kept so callers can reorder them."""
    _, o = vi(b, 0); _, o = vi(b, o)
    cx, cz = struct.unpack(">ii", b[o:o + 8]); o += 8
    hm_start = o
    n, o = vi(b, o); hms = []
    for _ in range(n):
        s = o
        k, o = vi(b, o); ln, o = vi(b, o); vals = b[o:o + 8 * ln]; o += 8 * ln
        hms.append((k, vals, b[s:o]))
    hm_end = o
    bl, o = vi(b, o); sec = b[o:o + bl]; o += bl
    secs = []; so = 0
    while so < len(sec):
        cnt, fl = struct.unpack(">hh", sec[so:so + 4]); so += 4
        bb, bp, bd, so = container(sec, so, 4096, False)
        mb, mp, md, so = container(sec, so, 64, True)
        secs.append(dict(count=cnt, fluid=fl, bits=bb, pal=bp, data=bd, bbits=mb, bpal=mp, bdata=md))
    be_n, o = vi(b, o); bes = []
    for _ in range(be_n):
        packed = b[o]; y = struct.unpack(">h", b[o + 1:o + 3])[0]; o += 3
        t, o = vi(b, o)
        s = o; tag = b[o]; o += 1
        if tag != 0:
            o = skip_nbt(b, o, 10)
        bes.append(dict(packed=packed, y=y, type=t, nbt=b[s:o]))
    masks = []
    for _ in range(4):
        m, o = bitset(b, o); masks.append(m)
    lists = []
    for _ in range(2):
        c, o = vi(b, o); arrs = []
        for _ in range(c):
            ln, o = vi(b, o); arrs.append(b[o:o + ln]); o += ln
        lists.append(arrs)
    assert o == len(b), (o, len(b))
    return dict(cx=cx, cz=cz, hms=hms, hm_start=hm_start, hm_end=hm_end, secs=secs, bes=bes, masks=masks, sky=lists[0], blk=lists[1])
