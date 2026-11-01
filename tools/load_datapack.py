#!/usr/bin/env python3
"""Load the data-driven registries and tags of a vanilla server into readable rows (ref.dp_*), from a capture of its configuration phase.

usage: tools/load_datapack.py [CAPTURE.jsonl]
       default capture: $DBCRAFT_DATAPACK_CAPTURE, else the newest tests/fixtures/captured/play*.jsonl of this or the parent checkout
Make a capture with:  tools/capture_vanilla.py --out tests/fixtures/captured/play_nocomp.jsonl      (needs a running vanilla 26.3 server)
Connection: libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE) or DBCRAFT_PSQL.  Needs the ref.* tables from tools/load_reports.py first
(static registries such as minecraft:block resolve tag members by their generated protocol ids).

What it stores: every registry_data entry as a tree of NBT nodes (type, key, order, value; nothing is lost: byte/short/int/long/float/double
stay distinct) and every update_tags tag as an ordered member list of names.  These are Mojang's data: they are read from your own server
at load time and never committed.  The rows are the source of truth; the packets are re-encoded from them in SQL (sql/140_registry.sql)
and tests/sql/140_net_registry.sql proves the re-encoding is byte-identical to the capture.
"""
import glob, json, os, struct, subprocess, sys

here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()

def find_capture():
    if len(sys.argv) > 1: return sys.argv[1]
    if os.environ.get("DBCRAFT_DATAPACK_CAPTURE"): return os.environ["DBCRAFT_DATAPACK_CAPTURE"]
    c = glob.glob(os.path.join(here, "tests/fixtures/captured/play*.jsonl")) + glob.glob("/home/user/dbcraft/tests/fixtures/captured/play*.jsonl")
    if not c: sys.exit("no capture found: run tools/capture_vanilla.py first")
    return max(c, key=os.path.getmtime)

def esc(v):
    if v is None: return r"\N"
    return str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
def sh(sql, data=None):
    p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql], input=data, capture_output=True)
    if p.returncode: sys.exit(f"psql failed: {p.stderr.decode()}\nSQL: {sql[:200]}")
def copy(table, cols, rows):
    sh(f"COPY {table} ({','.join(cols)}) FROM STDIN", "".join("\t".join(esc(c) for c in r) + "\n" for r in rows).encode())

# ---------------------------------------------------------------- wire readers
def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 127) << s
        if not c & 128: return v, o
        s += 7
def rstr(b, o):
    n, o = vi(b, o); return b[o:o + n].decode("utf8"), o + n
def mutf8(raw):
    """Java modified UTF-8 -> str (NUL as C0 80, supplementary characters as surrogate pairs)."""
    s = raw.replace(b"\xc0\x80", b"\x00").decode("utf8", "surrogatepass")
    return s.encode("utf-16", "surrogatepass").decode("utf-16")

class Tree:
    """NBT -> node rows (registry, entry, node, parent, idx, key, tag, elem_tag, i, f, s, arr)."""
    def __init__(self, reg, entry): self.reg, self.entry, self.n, self.rows = reg, entry, 0, []
    def parse(self, b, o, t, parent, idx, key):
        self.n += 1; me = self.n
        row = {"node": me, "parent": parent, "idx": idx, "key": key, "tag": t, "elem_tag": None, "i": None, "f": None, "s": None, "arr": None}
        self.rows.append(row)
        if   t == 1: row["i"] = struct.unpack(">b", b[o:o+1])[0]; o += 1
        elif t == 2: row["i"] = struct.unpack(">h", b[o:o+2])[0]; o += 2
        elif t == 3: row["i"] = struct.unpack(">i", b[o:o+4])[0]; o += 4
        elif t == 4: row["i"] = struct.unpack(">q", b[o:o+8])[0]; o += 8
        elif t == 5: row["f"] = struct.unpack(">f", b[o:o+4])[0]; o += 4
        elif t == 6: row["f"] = struct.unpack(">d", b[o:o+8])[0]; o += 8
        elif t == 7:
            n = struct.unpack(">i", b[o:o+4])[0]; row["arr"] = list(struct.unpack(f">{n}b", b[o+4:o+4+n])); o += 4 + n
        elif t == 8:
            n = struct.unpack(">H", b[o:o+2])[0]; row["s"] = mutf8(b[o+2:o+2+n]); o += 2 + n
        elif t == 9:
            et = b[o]; n = struct.unpack(">i", b[o+1:o+5])[0]; o += 5; row["elem_tag"] = et
            for k in range(n): o = self.parse(b, o, et, me, k, None)
        elif t == 10:
            k = 0
            while True:
                tt = b[o]; o += 1
                if tt == 0: break
                ln = struct.unpack(">H", b[o:o+2])[0]; name = mutf8(b[o+2:o+2+ln]); o += 2 + ln
                o = self.parse(b, o, tt, me, k, name); k += 1
        elif t == 11:
            n = struct.unpack(">i", b[o:o+4])[0]; row["arr"] = list(struct.unpack(f">{n}i", b[o+4:o+4+4*n])); o += 4 + 4 * n
        elif t == 12:
            n = struct.unpack(">i", b[o:o+4])[0]; row["arr"] = list(struct.unpack(f">{n}q", b[o+4:o+4+8*n])); o += 4 + 8 * n
        else: raise ValueError(f"unknown NBT tag {t} in {self.reg}/{self.entry}")
        return o

def pgarr(a): return None if a is None else "{" + ",".join(map(str, a)) + "}"

# ---------------------------------------------------------------- read the capture
cap = find_capture()
rows = [json.loads(l) for l in open(cap)]
cfg = [r for r in rows if r["state"] == "configuration" and r["dir"] == "clientbound"]
reg_rows, entry_rows, node_rows, tagreg_rows, tagdef_rows, tagmem_rows = [], [], [], [], [], []
seq = 0
for r in cfg:
    wire = bytes.fromhex(r["hex"]); _, o = vi(wire, 0); _, o = vi(wire, o)
    if r["name"] == "minecraft:registry_data":
        reg, o = rstr(wire, o); n, o = vi(wire, o)
        reg_rows.append((reg, seq)); seq += 1
        for k in range(n):
            name, o = rstr(wire, o); has = wire[o]; o += 1
            entry_rows.append((reg, k, name, "t" if has else "f"))
            if has:
                t = wire[o]; o += 1
                tr = Tree(reg, name); o = tr.parse(wire, o, t, None, 0, None)
                for x in tr.rows:
                    node_rows.append((reg, name, x["node"], x["parent"], x["idx"], x["key"], x["tag"], x["elem_tag"], x["i"], x["f"], x["s"], pgarr(x["arr"])))
        if o != len(wire): sys.exit(f"registry_data {reg}: {len(wire) - o} bytes left over")
    elif r["name"] == "minecraft:update_tags":
        nreg, o = vi(wire, o)
        for ri in range(nreg):
            reg, o = rstr(wire, o); ntag, o = vi(wire, o); tagreg_rows.append((reg, ri))
            for ti in range(ntag):
                tag, o = rstr(wire, o); nm, o = vi(wire, o); tagdef_rows.append((reg, tag, ti))
                for k in range(nm):
                    mid, o = vi(wire, o); tagmem_rows.append((reg, tag, k, mid))
        if o != len(wire): sys.exit(f"update_tags: {len(wire) - o} bytes left over")
if not reg_rows or not tagreg_rows: sys.exit(f"{cap}: no registry_data / update_tags packets in the configuration phase")

# ---------------------------------------------------------------- store
sh("TRUNCATE ref.dp_node, ref.dp_entry, ref.dp_registry, ref.dp_tag_member, ref.dp_tag, ref.dp_tag_registry")
sh("CREATE TABLE IF NOT EXISTS ref.dp_tag_member_raw (registry text, tag text, ord int, member_id int); TRUNCATE ref.dp_tag_member_raw")
copy("ref.dp_registry", ["registry", "seq"], reg_rows)
copy("ref.dp_entry", ["registry", "seq", "name", "has_data"], entry_rows)
copy("ref.dp_node", ["registry", "entry", "node", "parent", "idx", "key", "tag", "elem_tag", "i", "f", "s", "arr"], node_rows)
copy("ref.dp_tag_registry", ["registry", "seq"], tagreg_rows)
copy("ref.dp_tag", ["registry", "tag", "seq"], tagdef_rows)
copy("ref.dp_tag_member_raw", ["registry", "tag", "ord", "member_id"], tagmem_rows)
# member ids -> names: data-driven registries count from their registry_data order, built-in ones use the generated protocol ids
sh("""INSERT INTO ref.dp_tag_member (registry, tag, ord, member)
      SELECT r.registry, r.tag, r.ord,
             COALESCE((SELECT e.name FROM ref.dp_entry e WHERE e.registry = r.registry AND e.seq = r.member_id),
                      (SELECT g.name FROM ref.registry g WHERE g.registry = r.registry AND g.protocol_id = r.member_id))
      FROM ref.dp_tag_member_raw r""")
sh("DROP TABLE ref.dp_tag_member_raw")
sh("ANALYZE ref.dp_node, ref.dp_entry, ref.dp_tag_member")
print(f"loaded {len(reg_rows)} registries, {len(entry_rows)} entries, {len(node_rows)} nodes, "
      f"{len(tagreg_rows)} tag registries, {len(tagdef_rows)} tags, {len(tagmem_rows)} tag members from {cap}")
