#!/usr/bin/env python3
"""Export a dbcraft dimension to a vanilla Java world folder (Anvil region files, 26.3 layout) that the real server loads.

usage: tools/world_export.py OUT_WORLD_DIR [--dimension minecraft:overworld] [--box CX1 CZ1 CX2 CZ2] [--no-level] [--no-players] [--data-version 5023]
Connection: libpq environment or DBCRAFT_PSQL.  Standard library only (tools/world_import/anvil.py writes NBT and region files).
Writes OUT/dimensions/<ns>/<name>/region/r.X.Z.mca (zlib), OUT/level.dat and OUT/data/minecraft/*.dat (clock, weather, game rules) and OUT/players/data/<uuid>.dat.
Start a vanilla server with level-seed set to the seed printed at the end (the exporter does not write world_gen_settings.dat: a vanilla server without it
uses server.properties, and chunks that were not exported are generated from that seed).

Every chunk is brought up to date first (mc.ensure_chunk_current: light and heightmaps of edited chunks), then written with Status minecraft:full.
Block entities are written with their full save data when the world was imported (mc.block_entity.save_nbt), otherwise with what the chunk packet holds.
Not written: entities, structure starts and references, POI, ticks, raids, scoreboard, advancements.  OCEAN_FLOOR is left to the server (it primes missing heightmaps).
"""
import argparse, gzip, json, os, subprocess, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "world_import"))
import anvil as A

PSQL = os.environ.get("DBCRAFT_PSQL", "psql").split()


def q(sql):
    p = subprocess.run(PSQL + ["-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True)
    if p.returncode:
        sys.exit("psql failed: %s\n%s" % (sql[:150], p.stderr.decode()))
    return p.stdout.decode().splitlines()


def sql_lit(s):
    return "'" + str(s).replace("'", "''") + "'"


def ceillog2(n):
    return (n - 1).bit_length() if n > 1 else 0


def parse_arr(s):
    """A PostgreSQL text[] of quoted names (no quotes or backslashes inside) -> list."""
    s = s.strip()
    if s in ("", "{}", "\\N"):
        return []
    out, i, body = [], 0, s[1:-1]
    while i < len(body):
        if body[i] == '"':                                            # quoted element (names with commas or brackets)
            j = i + 1
            cur = []
            while body[j] != '"':
                if body[j] == "\\":
                    j += 1
                cur.append(body[j])
                j += 1
            out.append("".join(cur))
            i = j + 2
        else:
            j = body.find(",", i)
            j = len(body) if j < 0 else j
            out.append(body[i:j])
            i = j + 1
    return out


def parse_nums(s):
    s = s.strip()
    return [] if s in ("", "{}", "\\N") else [int(v) for v in s[1:-1].split(",")]


def hexbytes(s):
    if s == "\\N":
        return None
    assert s.startswith("\\\\x"), s[:12]
    return bytes.fromhex(s[3:])


def pack(entries, bits):
    per = 64 // bits
    out = []
    for i in range(0, len(entries), per):
        w = 0
        for j, v in enumerate(entries[i:i + per]):
            w |= v << (j * bits)
        out.append(w - (1 << 64) if w >= (1 << 63) else w)         # NBT longs are signed
    return A.LongArray(out)


def unpack_bytes(data, bits, n):
    per = 64 // bits
    mask = (1 << bits) - 1
    out = []
    for k in range(0, len(data), 8):
        w = int.from_bytes(data[k:k + 8], "big")
        for j in range(per):
            out.append((w >> (j * bits)) & mask)
            if len(out) == n:
                return out
    return out


def state_entry(name):
    """'minecraft:oak_log[axis=y]' -> the palette entry compound 26.3 reads: {id, properties}."""
    if "[" not in name:
        return {"id": name}
    base, rest = name.split("[", 1)
    props = {}
    for kv in rest[:-1].split(","):
        k, v = kv.split("=", 1)
        props[k] = v
    return {"id": base, "properties": props}


def block_states(pal, bits, data, state_name):
    if bits == 0:
        return {"palette": A.ListTag([state_entry(pal[0])], A.TAG_COMPOUND)}
    if bits == 16:                                                    # global palette: entries are state ids -> a palette of the names in use
        ents = unpack_bytes(data, 16, 4096)
        order = {}
        for e in ents:
            order.setdefault(e, len(order))
        names = [state_name[i] for i in order]
        bw = max(4, ceillog2(len(names)))
        return {"palette": A.ListTag([state_entry(n) for n in names], A.TAG_COMPOUND), "data": pack([order[e] for e in ents], bw)}
    return {"palette": A.ListTag([state_entry(n) for n in pal], A.TAG_COMPOUND),
            "data": A.LongArray(struct.unpack(">%dq" % (len(data) // 8), data))}


def biomes(pal, bits, data, biome_name):
    if bits == 0:
        return {"palette": A.ListTag([pal[0]], A.TAG_STRING)}
    if bits == 7:
        ents = unpack_bytes(data, 7, 64)
        order = {}
        for e in ents:
            order.setdefault(e, len(order))
        names = [biome_name[i] for i in order]
        bw = max(1, ceillog2(len(names)))
        return {"palette": A.ListTag(names, A.TAG_STRING), "data": pack([order[e] for e in ents], bw)}
    return {"palette": A.ListTag(list(pal), A.TAG_STRING), "data": A.LongArray(struct.unpack(">%dq" % (len(data) // 8), data))}


def chunk_nbt(cx, cz, rows, ctx):
    """rows: {'hm': (mb, nl, ws), 'sections': {sy: row}, 'light': {idx: row}, 'be': [row]} -> chunk compound."""
    secs = {}
    for sy, r in rows["sections"].items():
        secs[sy] = {"Y": A.Byte(sy), "block_states": block_states(r["pal"], r["bits"], r["data"], ctx["state_name"]),
                    "biomes": biomes(r["bpal"], r["bbits"], r["bdata"], ctx["biome_name"])}
    for idx, r in rows["light"].items():
        sy = idx - 1 + ctx["min_sy"]
        sec = secs.setdefault(sy, None)
        if sec is None and ctx["min_sy"] <= sy < ctx["min_sy"] + ctx["n_sections"]:        # light but no stored blocks: an all-air section
            sec = secs[sy] = {"Y": A.Byte(sy), "block_states": {"palette": A.ListTag([{"id": "minecraft:air"}], A.TAG_COMPOUND)},
                              "biomes": {"palette": A.ListTag([ctx["default_biome"]], A.TAG_STRING)}}
        elif sec is None:                                                                  # the light layers above and below the world
            sec = secs[sy] = {"Y": A.Byte(sy)}
        if r["sky"] is not None:
            sec["SkyLight"] = A.ByteArray(r["sky"])
        if r["block"] is not None:
            sec["BlockLight"] = A.ByteArray(r["block"])
    sections = A.ListTag([secs[k] for k in sorted(secs)], A.TAG_COMPOUND)
    hb = ceillog2(ctx["height"] + 1)
    hm = {}
    for key, vals in zip(("MOTION_BLOCKING", "MOTION_BLOCKING_NO_LEAVES", "WORLD_SURFACE"), rows["hm"]):
        if vals:
            hm[key] = pack(vals, hb)
    bes = A.ListTag([], A.TAG_COMPOUND)
    for r in rows["be"]:
        if r["save"] is not None:
            _, body = A.parse_nbt(r["save"], network=True)
        elif r["nbt"] and r["nbt"] != b"\x00":
            _, body = A.parse_nbt(r["nbt"], network=True)
        else:
            body = {}
        be = {"id": r["type"], "x": r["x"], "y": r["y"], "z": r["z"], "keepPacked": A.Byte(0)}
        be.update(body)
        bes.append(be)
    return {
        "DataVersion": ctx["data_version"], "Status": "minecraft:full", "xPos": cx, "yPos": ctx["min_sy"], "zPos": cz,
        "LastUpdate": A.Long(ctx["game_time"]), "InhabitedTime": A.Long(0), "isLightOn": A.Byte(1),
        "sections": sections, "Heightmaps": hm, "block_entities": bes,
        "structures": {"References": {}, "starts": {}},
        "block_ticks": A.ListTag([], A.TAG_COMPOUND), "fluid_ticks": A.ListTag([], A.TAG_COMPOUND),
        "PostProcessing": A.ListTag([A.ListTag([], A.TAG_END) for _ in range(ctx["n_sections"])], A.TAG_LIST),
    }


def fetch_region(dim, rx, rz, box):
    """All rows of the chunks of region (rx, rz) -> {(cx, cz): rows}."""
    x0, x1, z0, z1 = rx * 32, rx * 32 + 31, rz * 32, rz * 32 + 31
    if box:
        x0, x1, z0, z1 = max(x0, box[0]), min(x1, box[2]), max(z0, box[1]), min(z1, box[3])
    where = "dimension = %s and cx between %d and %d and cz between %d and %d" % (sql_lit(dim), x0, x1, z0, z1)
    chunks = {}
    for l in q("select cx, cz, coalesce(hm_motion_blocking::text, ''), coalesce(hm_motion_blocking_no_leaves::text, ''), coalesce(hm_world_surface::text, '') "
               "from mc.chunk where %s and status = 'minecraft:full'" % where):
        cx, cz, a, b, c = l.split("\t")
        chunks[(int(cx), int(cz))] = {"hm": (parse_nums(a), parse_nums(b), parse_nums(c)), "sections": {}, "light": {}, "be": []}
    for l in q("select cx, cz, sy, palette::text, bits, encode(data, 'hex'), biome_palette::text, biome_bits, encode(biome_data, 'hex') from mc.chunk_section where %s" % where):
        cx, cz, sy, pal, bits, data, bpal, bbits, bdata = l.split("\t")
        k = (int(cx), int(cz))
        if k in chunks:
            chunks[k]["sections"][int(sy)] = {"pal": parse_arr(pal), "bits": int(bits), "data": bytes.fromhex(data), "bpal": parse_arr(bpal),
                                              "bbits": int(bbits), "bdata": bytes.fromhex(bdata)}
    for l in q("select cx, cz, idx, sky_kind, coalesce(encode(sky, 'hex'), ''), block_kind, coalesce(encode(block, 'hex'), '') from mc.chunk_light where %s" % where):
        cx, cz, idx, sk, sky, bk, blk = l.split("\t")
        k = (int(cx), int(cz))
        if k in chunks:
            chunks[k]["light"][int(idx)] = {"sky": bytes.fromhex(sky) if sk == "data" and sky else None, "block": bytes.fromhex(blk) if bk == "data" and blk else None}
    for l in q("select cx, cz, x, y, z, type, encode(nbt, 'hex'), coalesce(encode(save_nbt, 'hex'), '') from mc.block_entity where %s order by seq" % where):
        cx, cz, x, y, z, t, nbt, save = l.split("\t")
        k = (int(cx), int(cz))
        if k in chunks:
            chunks[k]["be"].append({"x": int(x), "y": int(y), "z": int(z), "type": t, "nbt": bytes.fromhex(nbt), "save": bytes.fromhex(save) if save else None})
    return chunks


def write_gz(path, root_name, compound):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(gzip.compress(A.write_nbt(compound, root_name), 6))


def export_level(out, dim, ctx):
    gs = q("select game_time, day_time, raining, thundering, spawn_x, spawn_y, spawn_z, spawn_yaw from mc.game_state")
    gt, dt, rain, thunder, sx, sy, sz, syaw = gs[0].split("\t") if gs else ("0", "0", "f", "f", "0", "64", "0", "0")
    seed = (q("select seed from mc.world limit 1") or ["0"])[0]
    dq = q("select spawn_x, spawn_y, spawn_z from mc.dimension where name = %s" % sql_lit(dim))
    px, py, pz = (int(v) for v in dq[0].split("\t")) if dq else (int(float(sx)), int(float(sy)), int(float(sz)))
    props = dict(l.split("\t") for l in q("select key, value from mc.server_property where key in ('difficulty', 'gamemode')"))
    gamemode = {"survival": 0, "creative": 1, "adventure": 2, "spectator": 3}.get(props.get("gamemode", "survival"), 0)
    level = {"Data": {
        "difficulty_settings": {"difficulty": props.get("difficulty", "normal"), "hardcore": A.Byte(0), "locked": A.Byte(0)},
        "Time": A.Long(int(gt)), "version_history": A.ListTag([ctx["data_version"]], A.TAG_INT), "GameType": gamemode,
        "ServerBrands": A.ListTag(["dbcraft"], A.TAG_STRING), "version": 19133, "LastPlayed": A.Long(int(time.time() * 1000)),
        "spawn": {"pos": A.IntArray([px, py, pz]), "pitch": A.Float(0.0), "dimension": dim, "yaw": A.Float(float(syaw))},
        "Version": {"Snapshot": A.Byte(0), "Series": "main", "Id": ctx["data_version"], "Name": "26.3"},
        "LevelName": "world", "initialized": A.Byte(1), "WasModded": A.Byte(0), "DataVersion": ctx["data_version"], "allowCommands": A.Byte(0),
        "DataPacks": {"Enabled": A.ListTag(["vanilla"], A.TAG_STRING), "Disabled": A.ListTag([], A.TAG_STRING)}}}
    write_gz(os.path.join(out, "level.dat"), "", level)
    d = os.path.join(out, "data", "minecraft")
    def noise(settings, biome_source):
        return {"generator": {"settings": "minecraft:" + settings, "biome_source": biome_source, "type": "minecraft:noise"}, "type": "minecraft:" + {"overworld": "overworld", "nether": "the_nether", "end": "the_end"}[settings]}
    multi = lambda p: {"preset": "minecraft:" + p, "type": "minecraft:multi_noise"}
    write_gz(os.path.join(d, "world_gen_settings.dat"), "", {"data": {
        "bonus_chest": A.Byte(0), "seed": A.Long(int(seed)), "generate_structures": A.Byte(1),
        "dimensions": {"minecraft:overworld": noise("overworld", multi("overworld")), "minecraft:the_nether": noise("nether", multi("nether")),
                       "minecraft:the_end": noise("end", {"type": "minecraft:the_end"})}}, "DataVersion": ctx["data_version"]})
    write_gz(os.path.join(d, "world_clocks.dat"), "", {"data": {"minecraft:overworld": {"total_ticks": A.Long(int(dt))}}, "DataVersion": ctx["data_version"]})
    write_gz(os.path.join(d, "weather.dat"), "", {"data": {"raining": A.Byte(1 if rain == "t" else 0), "thundering": A.Byte(1 if thunder == "t" else 0),
                                                           "rain_time": 0, "thunder_time": 0, "clear_weather_time": 0}, "DataVersion": ctx["data_version"]})
    rules = q("select name, value from mc.game_rule") if q("select to_regclass('mc.game_rule') is not null")[0] == "t" else []
    if rules:
        rd = {}
        for l in rules:
            n, v = l.split("\t")
            rd[n] = A.Byte(1 if v == "true" else 0) if v in ("true", "false") else int(v)
        write_gz(os.path.join(d, "game_rules.dat"), "", {"data": rd, "DataVersion": ctx["data_version"]})
    return seed


SLOT_BACK = {}                                  # menu slot -> anvil slot
for _d in range(0, 9):
    SLOT_BACK[36 + _d] = _d
for _d in range(9, 36):
    SLOT_BACK[_d] = _d
SLOT_BACK.update({5: 103, 6: 102, 7: 101, 8: 100, 45: -106})


def json_nbt(v):
    if isinstance(v, dict):
        return {k: json_nbt(x) for k, x in v.items()}
    if isinstance(v, list):
        items = [json_nbt(x) for x in v]
        et = A.tag_type(items[0]) if items else A.TAG_END
        return A.ListTag(items, et)
    if isinstance(v, bool):
        return A.Byte(1 if v else 0)
    return v


def export_players(out, dim, ctx):
    n = 0
    for l in q("select uuid, gamemode, health, food, saturation, xp_level, held_slot, x, y, z, yaw, pitch, on_ground from mc.player"):
        u, gm, hp, food, sat, xp, held, x, y, z, yaw, pitch, og = l.split("\t")
        h = u.replace("-", "")
        uuid_ints = A.IntArray([int(h[i:i + 8], 16) - (1 << 32) if int(h[i:i + 8], 16) >= (1 << 31) else int(h[i:i + 8], 16) for i in range(0, 32, 8)])
        inv = A.ListTag([], A.TAG_COMPOUND)
        for r in q("select slot, item, count, coalesce(components::text, '') from mc.inventory_slot where player = %s order by slot" % sql_lit(u)):
            slot, item, count, comp = r.split("\t")
            if int(slot) not in SLOT_BACK:
                continue
            e = {"Slot": A.Byte(SLOT_BACK[int(slot)]), "id": item, "count": int(count)}
            if comp:
                e["components"] = json_nbt(json.loads(comp))
            inv.append(e)
        p = {"DataVersion": ctx["data_version"], "UUID": uuid_ints, "Dimension": dim, "playerGameType": int(gm),
             "Pos": A.ListTag([float(x), float(y), float(z)], A.TAG_DOUBLE), "Rotation": A.ListTag([A.Float(float(yaw)), A.Float(float(pitch))], A.TAG_FLOAT),
             "Health": A.Float(float(hp)), "foodLevel": int(food), "foodSaturationLevel": A.Float(float(sat)), "XpLevel": int(xp),
             "SelectedItemSlot": int(held), "OnGround": A.Byte(1 if og == "t" else 0), "Inventory": inv}
        write_gz(os.path.join(out, "players", "data", u + ".dat"), "", p)
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--dimension", default="minecraft:overworld")
    ap.add_argument("--box", nargs=4, type=int, metavar=("CX1", "CZ1", "CX2", "CZ2"))
    ap.add_argument("--no-level", action="store_true")
    ap.add_argument("--no-players", action="store_true")
    ap.add_argument("--data-version", type=int, default=5023)
    a = ap.parse_args()
    t0 = time.time()
    dq = q("select min_y, height, default_biome from mc.dimension where name = %s" % sql_lit(a.dimension))
    if not dq:
        sys.exit("unknown dimension " + a.dimension)
    min_y, height, default_biome = dq[0].split("\t")
    ctx = {"min_sy": int(min_y) >> 4, "n_sections": int(height) >> 4, "height": int(height), "default_biome": default_biome, "data_version": a.data_version,
           "game_time": int((q("select game_time from mc.game_state") or ["0"])[0]),
           "state_name": {int(i): n for i, n in (l.split("\t") for l in q("select state_id, name from ref.block_state"))},
           "biome_name": {int(i): n for i, n in (l.split("\t") for l in q("select id, name from mc.biome"))}}
    # bring edited chunks up to date (light and heightmaps), set-based per chunk
    todo = q("select cx, cz from mc.chunk where dimension = %s and status = 'minecraft:full' and (dirty or hm_dirty or hm_world_surface is null)" % sql_lit(a.dimension))
    if todo:
        q("select mc.ensure_chunk_current(%s, cx, cz) from mc.chunk where dimension = %s and status = 'minecraft:full' and (dirty or hm_dirty or hm_world_surface is null)"
          % (sql_lit(a.dimension), sql_lit(a.dimension)))
    ns, _, name = a.dimension.partition(":")
    folder = os.path.join(a.out, "dimensions", ns, name, "region")
    os.makedirs(folder, exist_ok=True)
    regions = sorted({(int(x) >> 5, int(z) >> 5) for x, z in (l.split("\t") for l in q("select cx, cz from mc.chunk where dimension = %s and status = 'minecraft:full'" % sql_lit(a.dimension)))})
    n = 0
    for rx, rz in regions:
        rows = fetch_region(a.dimension, rx, rz, a.box)
        if not rows:
            continue
        data = {k: A.write_nbt(chunk_nbt(k[0], k[1], r, ctx), "") for k, r in rows.items()}
        A.write_region(os.path.join(folder, "r.%d.%d.mca" % (rx, rz)), data)
        n += len(rows)
    seed = None
    if not a.no_level and a.dimension == "minecraft:overworld":
        seed = export_level(a.out, a.dimension, ctx)
    np_ = 0 if a.no_players else export_players(a.out, a.dimension, ctx)
    print("exported %d chunks of %s in %d region files to %s in %.1f s (%.0f chunks/s)%s%s"
          % (n, a.dimension, len(regions), a.out, time.time() - t0, n / max(time.time() - t0, 1e-9), ("; %d players" % np_) if np_ else "",
             ("; use level-seed=%s" % seed) if seed is not None else ""))


if __name__ == "__main__":
    main()
