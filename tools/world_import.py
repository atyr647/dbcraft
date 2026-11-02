#!/usr/bin/env python3
"""Import a vanilla Java world (Anvil region files, 26.3 layout) into dbcraft's tables.

usage: tools/world_import.py WORLD_DIR [--dimension minecraft:overworld] [--replace] [--jobs N] [--limit N]
                             [--box CX1 CZ1 CX2 CZ2] [--work DIR] [--no-level] [--no-players] [--stats]
Connection: libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE) or DBCRAFT_PSQL="psql -h ... -d ...".
Needs the schema migrated (sql/*.sql incl. sql/700), reference data (tools/load_reports.py) and world reference data (tools/load_world_ref.py: biome ids).
Standard library only: NBT and region parsing are in tools/world_import/anvil.py.

What is imported: every chunk with Status minecraft:full of the chosen dimension: block sections (palette by readable block-state name + packed longs, reused
as they are on disk whenever the bit width matches the network format), biomes, the three heightmaps the chunk packet carries, sky and block light, block
entities (as the update tag the chunk packet carries).  Also level data (seed, spawn, clock, weather, difficulty, game rules) and player data.
What is NOT imported: entities, structure data, POI, ticks, raids, scoreboard, advancements, statistics.  See docs/WORLD-IMPORT.md.
"""
import argparse, collections, concurrent.futures, gzip, json, os, subprocess, sys, tempfile, time, struct

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "world_import"))
import anvil as A

PSQL = os.environ.get("DBCRAFT_PSQL", "psql").split()
HM_KEYS = ("MOTION_BLOCKING", "MOTION_BLOCKING_NO_LEAVES", "WORLD_SURFACE")
# block entities whose chunk-packet tag is the save data without id/x/y/z/keepPacked (saveCustomOnly / saveWithoutMetadata in 26.3, read with javap)
CUSTOM_TAG_TYPES = {
    "minecraft:banner", "minecraft:beacon", "minecraft:conduit", "minecraft:creaking_heart", "minecraft:decorated_pot", "minecraft:jigsaw",
    "minecraft:sign", "minecraft:hanging_sign", "minecraft:skull", "minecraft:mob_spawner", "minecraft:structure_block", "minecraft:end_gateway",
    "minecraft:test_block", "minecraft:test_instance_block",
}


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, **kw)


def psql_text(sql):
    p = sh(PSQL + ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-F", "\t", "-c", sql])
    if p.returncode:
        sys.exit("psql failed: %s\n%s" % (sql[:120], p.stderr.decode()))
    return p.stdout.decode()


def ceillog2(n):
    return (n - 1).bit_length() if n > 1 else 0


def pack(entries, bits):
    """Vanilla SimpleBitStorage: floor(64/bits) entries per long, least significant first, no entry spans two longs; returns big-endian bytes."""
    per = 64 // bits
    out = bytearray()
    for i in range(0, len(entries), per):
        w = 0
        for j, v in enumerate(entries[i:i + per]):
            w |= v << (j * bits)
        out += struct.pack(">Q", w)
    return bytes(out)


def unpack(longs, bits, n):
    per = 64 // bits
    mask = (1 << bits) - 1
    out = []
    for w in longs:
        w &= 0xFFFFFFFFFFFFFFFF
        for j in range(per):
            out.append((w >> (j * bits)) & mask)
            if len(out) == n:
                return out
    if len(out) < n:
        raise ValueError("packed array too short")
    return out


def longs_needed(n, bits):
    per = 64 // bits
    return -(-n // per)


def infer_bits(nlongs, n, at_least):
    for b in range(max(at_least, 1), 17):
        if longs_needed(n, b) == nlongs:
            return b
    raise ValueError("cannot infer the bit width from %d longs" % nlongs)


# ----------------------------------------------------------------------------------------------------------------------- COPY text helpers
def arr(items):
    return "{" + ",".join('"' + i.replace("\\", "\\\\").replace('"', '\\"') + '"' for i in items) + "}"


def bytea(b):
    return "\\\\x" + b.hex()


def nums(xs):
    return "{" + ",".join(map(str, xs)) + "}"


# ----------------------------------------------------------------------------------------------------------------------- conversion
class Ctx:
    defaults = {}                  # block name -> properties of its default state (a palette entry without properties means the default state)
    lookup = {}                    # (block, frozenset of property items) -> readable state name as ref.block_state writes it (its own property order)
    state_name = {}                # state id -> name
    air = frozenset()              # names mc.is_air says are air
    fluid = frozenset()            # names mc.has_fluid says contain a fluid
    states = frozenset()
    state_id = {}
    biome_id = {}
    be_types = frozenset()
    min_sy = -4
    n_sections = 24
    height = 384
    dim = "minecraft:overworld"
    cache = {}


def entry_parts(entry):
    """A block-state palette entry in any of the forms 26.3 writes: a bare string (no properties), {"": name} (the same string wrapped because the list also
    holds compounds: NBT lists may mix types since 1.21.5), {id, properties} (26.x keys), or the older {Name, Properties}."""
    if isinstance(entry, str):
        return entry, None
    if "" in entry:
        return entry[""], None
    return entry.get("id", entry.get("Name")), entry.get("properties", entry.get("Properties"))


def canon(entry, ctx, stats):
    name, props = entry_parts(entry)
    key = (name, tuple(sorted(props.items())) if props else None)
    r = ctx.cache.get(key)
    if r is None:
        merged = dict(ctx.defaults.get(name, {}))          # absent properties = the block's default state; given ones override
        if props:
            merged.update({k: str(v) for k, v in props.items()})
        r = ctx.lookup.get((name, frozenset(merged.items())))
        if r is None:
            stats["unknown_state"] = stats.get("unknown_state", 0) + 1
            stats.setdefault("unknown_names", set()).add(name + str(sorted(merged.items())))
            r = "minecraft:air"
        ctx.cache[key] = r
    return r


def counts(pal, bits, data, ctx):
    """(block_count, fluid_count) of a section in the wire format, with the classification mc.is_air / mc.has_fluid use (loaded into ctx.air / ctx.fluid).
    Histogram of the palette indices without a Python loop over 4,096 entries: bits=4 reads the hex digits of the big-endian bytes, bits=8 the bytes."""
    if bits == 0:
        return (0 if pal[0] in ctx.air else 4096), (4096 if pal[0] in ctx.fluid else 0)
    n = len(pal)
    if bits == 4:
        hx = data.hex()
        hist = {i: hx.count("%x" % i) for i in range(n)}
    elif bits == 8:
        hist = {}
        for v, c in collections.Counter(data).items():
            hist[v] = c
    else:
        longs = struct.unpack(">%dQ" % (len(data) // 8), data)
        per = 64 // bits
        mask = (1 << bits) - 1
        cnt = collections.Counter()
        full = 4096 // per                           # longs that are filled completely; the last one may be partly padding
        for j in range(per):
            sh = j * bits
            cnt.update([(w >> sh) & mask for w in longs[:full]])
        rest = 4096 - full * per
        if rest:
            w = longs[full]
            for j in range(rest):
                cnt[(w >> (j * bits)) & mask] += 1
        hist = dict(cnt)
    if bits == 16:                                    # global palette: the entries are state ids
        names = {i: ctx.state_name[i] for i in hist}
    else:
        names = {i: pal[i] for i in hist if i < n}
    blocks = sum(c for i, c in hist.items() if i in names and names[i] not in ctx.air)
    fluids = sum(c for i, c in hist.items() if i in names and names[i] in ctx.fluid)
    return blocks, fluids


def convert_blocks(bs, ctx, stats):
    """-> (palette names, bits, data bytes) in the wire format."""
    pal = [canon(e, ctx, stats) for e in bs["palette"]]
    n = len(pal)
    data = bs.get("data")
    if n == 1 or not data:
        return [pal[0]], 0, b""
    want = max(4, ceillog2(n)) if n <= 256 else None
    have = infer_bits(len(data), 4096, ceillog2(n))
    if want is not None and have == want:
        return pal, want, struct.pack(">%dq" % len(data), *data)           # reused as stored on disk
    entries = unpack(data, have, 4096)
    if want is not None:
        stats["repacked"] = stats.get("repacked", 0) + 1
        return pal, want, pack(entries, want)
    stats["global_palette"] = stats.get("global_palette", 0) + 1
    ids = [ctx.state_id[pal[i]] for i in range(n)]
    return [], 16, pack([ids[e] for e in entries], 16)


def convert_biomes(bm, ctx, stats):
    pal = list(bm["palette"])
    n = len(pal)
    data = bm.get("data")
    if n == 1 or not data:
        return [pal[0]], 0, b""
    want = ceillog2(n) if n <= 8 else None
    have = infer_bits(len(data), 64, ceillog2(n))
    if want is not None and have == want:
        return pal, want, struct.pack(">%dq" % len(data), *data)
    entries = unpack(data, have, 64)
    if want is not None:
        stats["biome_repacked"] = stats.get("biome_repacked", 0) + 1
        return pal, want, pack(entries, want)
    stats["biome_global"] = stats.get("biome_global", 0) + 1
    ids = [ctx.biome_id[p] for p in pal]
    return [], 7, pack([ids[e] for e in entries], 7)


def be_packet_nbt(t, be):
    if t == "minecraft:vault":                              # VaultBlockEntity.getUpdateTag: only the client-synced shared data (read with javap, confirmed on real vaults)
        return A.write_nbt({"shared_data": be.get("shared_data", {})}, network=True)
    if t not in CUSTOM_TAG_TYPES:
        return b"\x00"                                      # the default update tag is an empty compound, which the packet sends as "no tag"
    tag = {k: v for k, v in be.items() if k not in ("id", "x", "y", "z", "keepPacked")}
    if t != "minecraft:banner" and not tag.get("components"):
        tag.pop("components", None)                         # saveCustomOnly leaves out an empty components compound (seen on a real mob spawner);
                                                            # the banner's saveWithoutMetadata keeps it (seen on real banners)
    if t == "minecraft:mob_spawner":
        tag.pop("SpawnPotentials", None)
    return b"\x00" if not tag else A.write_nbt(tag, network=True)


def convert_chunk(cx, cz, c, ctx, stats):
    """-> dict of COPY text rows, or None for a chunk that is not full."""
    if str(c.get("Status")) != "minecraft:full":
        stats["skipped_" + str(c.get("Status", "?"))] = stats.get("skipped_" + str(c.get("Status", "?")), 0) + 1
        return None
    if c.get("xPos") != cx or c.get("zPos") != cz:
        stats["wrong_position"] = stats.get("wrong_position", 0) + 1
        return None
    d = ctx.dim
    hms = c.get("Heightmaps", {})
    hbits = ceillog2(ctx.height + 1)
    cols, hm_ok = [], True
    for k in HM_KEYS:
        v = hms.get(k)
        if v is None:
            hm_ok = False
            cols.append("\\N")
        else:
            cols.append(nums(unpack(v, hbits, 256)))
    light_on = bool(c.get("isLightOn", 0))
    dirty = "f" if (light_on and hm_ok) else "t"
    rows = {"chunk": ["\t".join([d, str(cx), str(cz), "minecraft:full", "0", dirty, "f" if hm_ok else "t"] + cols)], "section": [], "light": [], "be": []}
    light = {}
    for s in c.get("sections", []):
        sy = int(s["Y"])
        if "block_states" in s and ctx.min_sy <= sy < ctx.min_sy + ctx.n_sections:
            pal, bits, data = convert_blocks(s["block_states"], ctx, stats)
            bpal, bbits, bdata = convert_biomes(s["biomes"], ctx, stats)
            nb, nf = counts(pal, bits, data, ctx)
            rows["section"].append("\t".join([d, str(cx), str(cz), str(sy), str(nb), str(nf), arr(pal), str(bits), bytea(data), arr(bpal), str(bbits), bytea(bdata)]))
        sky, blk = s.get("SkyLight"), s.get("BlockLight")
        idx = sy - ctx.min_sy + 1
        if (sky is not None or blk is not None) and 0 <= idx <= ctx.n_sections + 1:
            light[idx] = (sky, blk)
    # The file stores only light layers that are not all dark; vanilla's packet marks the dark layers it has as "empty" (a mask bit without an array), for every layer
    # from the one below the world up to the highest layer that holds any light.  Reproduce that: missing arrays below the top are 'empty', above it absent.
    if light:
        for idx in range(0, max(light) + 1):
            sky, blk = light.get(idx, (None, None))
            rows["light"].append("\t".join([d, str(cx), str(cz), str(idx),
                                            "data" if sky is not None else "empty", bytea(bytes(sky)) if sky is not None else "\\N",
                                            "data" if blk is not None else "empty", bytea(bytes(blk)) if blk is not None else "\\N"]))
    for be in c.get("block_entities", []):
        t = str(be.get("id", ""))
        if t not in ctx.be_types:
            stats["skipped_block_entity_" + t] = stats.get("skipped_block_entity_" + t, 0) + 1
            continue
        x, y, z = int(be["x"]), int(be["y"]), int(be["z"])
        if x >> 4 != cx or z >> 4 != cz:
            stats["be_outside_chunk"] = stats.get("be_outside_chunk", 0) + 1
            continue
        rows["be"].append("\t".join([d, str(cx), str(cz), str(x), str(y), str(z), t, bytea(be_packet_nbt(t, be))]))
    return rows


def quick_status(raw):
    """The chunk's Status string read from the raw NBT without parsing it (None when the tag is not in the first 400 bytes)."""
    i = raw.find(b"\x08\x00\x06Status", 0, 400)
    if i < 0:
        return None
    n = int.from_bytes(raw[i + 9:i + 11], "big")
    return raw[i + 11:i + 11 + n].decode("utf-8", "replace")


def process_region(args):
    path, box = args
    stats = {}
    out = {"chunk": [], "section": [], "light": [], "be": []}
    n = 0
    for cx, cz, raw in A.read_region(path):
        if box and not (box[0] <= cx <= box[2] and box[1] <= cz <= box[3]):
            continue
        st = quick_status(raw)
        if st is not None and st != "minecraft:full":          # most chunks of a freshly generated world are intermediate: skip them without parsing
            stats["skipped_" + st] = stats.get("skipped_" + st, 0) + 1
            continue
        name, c = A.parse_nbt(raw)
        r = convert_chunk(cx, cz, c, CTX, stats)
        if r is None:
            continue
        n += 1
        for k in out:
            out[k].extend(r[k])
    stats["chunks"] = n
    return {k: "\n".join(v) + ("\n" if v else "") for k, v in out.items()}, stats


CTX = Ctx()


# ----------------------------------------------------------------------------------------------------------------------- level data and players
def read_gz(path):
    with open(path, "rb") as f:
        return A.parse_nbt(gzip.decompress(f.read()))[1]


def sql_lit(s):
    return "'" + str(s).replace("'", "''") + "'"


def import_level(world, dim, ctx):
    """seed, spawn, clock, weather, difficulty, game rules -> SQL statements."""
    stmts = []
    lvl = read_gz(os.path.join(world, "level.dat")).get("Data", {})
    dd = os.path.join(world, "data", "minecraft")

    def data(name):
        p = os.path.join(dd, name + ".dat")
        return read_gz(p).get("data", {}) if os.path.exists(p) else {}
    wg = data("world_gen_settings")
    if "seed" in wg:
        stmts.append("update mc.world set seed = %d" % int(wg["seed"]))
    sp = lvl.get("spawn") or {}
    if sp.get("pos"):
        x, y, z = (int(v) for v in sp["pos"])
        stmts.append("update mc.dimension set spawn_x = %d, spawn_y = %d, spawn_z = %d where name = %s" % (x, y, z, sql_lit(sp.get("dimension", dim))))
        stmts.append("update mc.game_state set spawn_x = %r, spawn_y = %r, spawn_z = %r, spawn_yaw = %r" % (x + 0.5, float(y), z + 0.5, float(sp.get("yaw", 0.0))))
    clocks = data("world_clocks")
    day = clocks.get("minecraft:overworld", {}).get("total_ticks", lvl.get("DayTime", lvl.get("Time", 0)))
    wt = data("weather")
    stmts.append("update mc.game_state set game_time = %d, day_time = %d, raining = %s, thundering = %s"
                 % (int(lvl.get("Time", 0)), int(day), "true" if wt.get("raining") else "false", "true" if wt.get("thundering") else "false"))
    ds = lvl.get("difficulty_settings", {})
    if "difficulty" in ds:
        stmts.append("update mc.server_property set value = %s where key = 'difficulty'" % sql_lit(ds["difficulty"]))
    gt = {0: "survival", 1: "creative", 2: "adventure", 3: "spectator"}.get(int(lvl.get("GameType", 0)))
    if gt:
        stmts.append("update mc.server_property set value = %s where key = 'gamemode'" % sql_lit(gt))
    rules = data("game_rules")
    if rules:
        stmts.append("create table if not exists mc.game_rule (name text primary key, value text not null)")
        stmts.append("delete from mc.game_rule")
        for k, v in sorted(rules.items()):
            val = ("true" if v else "false") if isinstance(v, A.Byte) else str(v)
            stmts.append("insert into mc.game_rule values (%s, %s)" % (sql_lit(k), sql_lit(val)))
    return stmts


def menu_slot(disk):
    """Anvil inventory slot -> the player-inventory menu numbering of mc.inventory_slot."""
    if 0 <= disk <= 8:
        return 36 + disk
    if 9 <= disk <= 35:
        return disk
    return {103: 5, 102: 6, 101: 7, 100: 8, -106: 45}.get(disk)


def nbt_json(v):
    if isinstance(v, dict):
        return {k: nbt_json(x) for k, x in v.items()}
    if isinstance(v, (A.LongArray, A.IntArray, list)):
        return [nbt_json(x) for x in v]
    if isinstance(v, A.ByteArray):
        return list(v)
    if isinstance(v, bool):
        return bool(v)
    if isinstance(v, (int, float, str)):
        return v
    return str(v)


def import_players(world, names):
    stmts = []
    pdir = os.path.join(world, "players", "data")
    if not os.path.isdir(pdir):
        pdir = os.path.join(world, "playerdata")
    if not os.path.isdir(pdir):
        return stmts
    for fn in sorted(os.listdir(pdir)):
        if not fn.endswith(".dat"):
            continue
        uuid = fn[:-4]
        p = read_gz(os.path.join(pdir, fn))
        pos = p.get("Pos", [0.0, 0.0, 0.0])
        rot = p.get("Rotation", [0.0, 0.0])
        name = names.get(uuid) or uuid[:16]
        stmts.append(
            "insert into mc.player (uuid, name, gamemode, health, food, saturation, xp_level, held_slot, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z) values "
            "(%s, %s, %d, %r, %d, %r, %d, %d, %r, %r, %r, %r, %r, %s, %d, %d) on conflict (uuid) do update set name = excluded.name, gamemode = excluded.gamemode, "
            "health = excluded.health, food = excluded.food, saturation = excluded.saturation, xp_level = excluded.xp_level, held_slot = excluded.held_slot, "
            "x = excluded.x, y = excluded.y, z = excluded.z, yaw = excluded.yaw, pitch = excluded.pitch, on_ground = excluded.on_ground, "
            "chunk_x = excluded.chunk_x, chunk_z = excluded.chunk_z"
            % (sql_lit(uuid), sql_lit(name), int(p.get("playerGameType", 0)), float(p.get("Health", 20.0)), int(p.get("foodLevel", 20)),
               float(p.get("foodSaturationLevel", 5.0)), int(p.get("XpLevel", 0)), int(p.get("SelectedItemSlot", 0)), float(pos[0]), float(pos[1]),
               float(pos[2]), float(rot[0]), float(rot[1]), "true" if p.get("OnGround", 1) else "false", int(float(pos[0]) // 16), int(float(pos[2]) // 16)))
        stmts.append("delete from mc.inventory_slot where player = %s" % sql_lit(uuid))
        for it in p.get("Inventory", []):
            slot = menu_slot(int(it.get("Slot", -1)))
            if slot is None or "id" not in it:
                continue
            comp = it.get("components")
            comp_sql = "null" if not comp else sql_lit(json.dumps(nbt_json(comp), separators=(",", ":"))) + "::jsonb"
            stmts.append("insert into mc.inventory_slot (player, slot, item, count, components) values (%s, %d, %s, %d, %s)"
                         % (sql_lit(uuid), slot, sql_lit(it["id"]), max(1, min(99, int(it.get("count", it.get("Count", 1))))), comp_sql))
    return stmts


# ----------------------------------------------------------------------------------------------------------------------- main
def load_ctx(dim):
    """Fill CTX from the database: the readable state names with their own property order, defaults, ids, classification, biome ids, block entity types."""
    dq = psql_text("select min_y, height from mc.dimension where name = %s" % sql_lit(dim)).strip()
    if not dq:
        sys.exit("dimension %s does not exist in mc.dimension" % dim)
    min_y, height = (int(x) for x in dq.split("\t"))
    CTX.dim, CTX.height, CTX.min_sy, CTX.n_sections = dim, height, min_y >> 4, height >> 4
    lookup, defaults, state_id, state_name = {}, {}, {}, {}
    for line in psql_text("select state_id, name, block, is_default from ref.block_state").splitlines():
        sid, name, block, is_def = line.split("\t")
        props = {}
        if "[" in name:
            for kv in name[name.index("[") + 1:-1].split(","):
                k, v = kv.split("=", 1)
                props[k] = v
        lookup[(block, frozenset(props.items()))] = name
        state_id[name] = int(sid)
        state_name[int(sid)] = name
        if is_def == "t":
            defaults[block] = props
    if not lookup:
        sys.exit("ref.block_state is empty: run tools/load_reports.py first")
    CTX.lookup, CTX.defaults, CTX.state_id, CTX.state_name = lookup, defaults, state_id, state_name
    CTX.states = frozenset(state_id)
    CTX.air = frozenset(psql_text("select name from ref.block_state where mc.is_air(name)").splitlines())
    CTX.fluid = frozenset(psql_text("select name from ref.block_state where mc.has_fluid(name)").splitlines())
    CTX.biome_id = {n: int(i) for n, i in (l.split("\t") for l in psql_text("select name, id from mc.biome").splitlines() if l)}
    CTX.be_types = frozenset(psql_text("select name from ref.registry where registry = 'minecraft:block_entity_type'").splitlines())


def dimension_folder(world, dim):
    ns, _, name = dim.partition(":")
    for cand in (os.path.join(world, "dimensions", ns, name, "region"),
                 {"minecraft:overworld": os.path.join(world, "region"), "minecraft:the_nether": os.path.join(world, "DIM-1", "region"),
                  "minecraft:the_end": os.path.join(world, "DIM1", "region")}.get(dim, "")):
        if cand and os.path.isdir(cand):
            return cand
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("world")
    ap.add_argument("--dimension", default="minecraft:overworld")
    ap.add_argument("--replace", action="store_true", help="delete existing chunks that the import overwrites")
    ap.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
    ap.add_argument("--limit", type=int, default=0, help="stop after N region files (testing)")
    ap.add_argument("--box", nargs=4, type=int, metavar=("CX1", "CZ1", "CX2", "CZ2"), help="only chunks in this box (chunk coordinates)")
    ap.add_argument("--work", help="keep the COPY files in this directory")
    ap.add_argument("--no-level", action="store_true")
    ap.add_argument("--no-players", action="store_true")
    ap.add_argument("--player-names", help="usercache.json (default: ../usercache.json next to the world)")
    a = ap.parse_args()
    t0 = time.time()
    folder = dimension_folder(a.world, a.dimension)
    if not folder:
        sys.exit("no region folder for %s under %s" % (a.dimension, a.world))
    load_ctx(a.dimension)
    work = a.work or tempfile.mkdtemp(prefix="world_import.")
    os.makedirs(work, exist_ok=True)
    files = A.region_files(folder)
    if a.limit:
        files = files[:a.limit]
    stats = {}
    handles = {k: open(os.path.join(work, k + ".tsv"), "w") for k in ("chunk", "section", "light", "be")}
    t1 = time.time()
    with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for out, st in ex.map(process_region, [(f, a.box) for f in files]):
            for k, v in out.items():
                handles[k].write(v)
            for k, v in st.items():
                if isinstance(v, set):
                    stats.setdefault(k, set()).update(v)
                else:
                    stats[k] = stats.get(k, 0) + v
    for h in handles.values():
        h.close()
    t_parse = time.time() - t1
    nchunks = stats.get("chunks", 0)
    # the load script: one transaction
    cols = {
        "chunk": "mc.chunk (dimension, cx, cz, status, version, dirty, hm_dirty, hm_motion_blocking, hm_motion_blocking_no_leaves, hm_world_surface)",
        "section": "mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data)",
        "light": "mc.chunk_light (dimension, cx, cz, idx, sky_kind, sky, block_kind, block)",
        "be": "mc.block_entity (dimension, cx, cz, x, y, z, type, nbt)",
    }
    script = ["\\set ON_ERROR_STOP on", "begin;"]
    if a.replace:
        script += ["create temp table imp_chunks (cx int, cz int) on commit drop;",
                   "\\copy imp_chunks (cx, cz) from program 'cut -f2,3 %s'" % os.path.join(work, "chunk.tsv"),
                   "delete from mc.chunk c using imp_chunks i where c.dimension = %s and c.cx = i.cx and c.cz = i.cz;" % sql_lit(a.dimension)]
    for k in ("chunk", "section", "light", "be"):
        script.append("\\copy %s from '%s'" % (cols[k], os.path.join(work, k + ".tsv")))
    if not a.no_level and a.dimension == "minecraft:overworld" and os.path.exists(os.path.join(a.world, "level.dat")):
        script += [s + ";" for s in import_level(a.world, a.dimension, CTX)]
    if not a.no_players:
        names = {}
        uc = a.player_names or os.path.join(os.path.dirname(os.path.abspath(a.world)), "usercache.json")
        if os.path.exists(uc):
            for e in json.load(open(uc)):
                names[e["uuid"]] = e["name"]
        script += [s + ";" for s in import_players(a.world, names)]
    script.append("commit;")
    sp = os.path.join(work, "load.sql")
    with open(sp, "w") as f:
        f.write("\n".join(script) + "\n")
    t2 = time.time()
    p = sh(PSQL + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", sp])
    if p.returncode:
        sys.exit("load failed:\n" + p.stderr.decode()[:2000] + "\n(the COPY files are in %s; for chunks that already exist use --replace)" % work)
    t_load = time.time() - t2
    total = time.time() - t0
    for k, v in sorted(stats.items()):
        if isinstance(v, set):
            print("  %s: %s" % (k, ", ".join(sorted(v)[:8])))
        elif k != "chunks":
            print("  %s: %d" % (k, v))
    print("imported %d chunks of %s from %d region files in %.1f s (parse %.1f s with %d jobs, load %.1f s): %.0f chunks/s overall, %.0f chunks/min"
          % (nchunks, a.dimension, len(files), total, t_parse, a.jobs, t_load, nchunks / total if total else 0, nchunks / total * 60 if total else 0))
    if not a.work:
        for k in handles:
            os.remove(os.path.join(work, k + ".tsv"))
        os.remove(sp)
        os.rmdir(work)


if __name__ == "__main__":
    main()
