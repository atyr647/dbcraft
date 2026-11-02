#!/usr/bin/env python3
"""Compare the chunk packets of a REAL vanilla server with dbcraft's packets for the same chunks, component by component.

usage: tests/world_import/compare_chunks.py CAPTURE.jsonl [--dimension minecraft:overworld] [--examples N] [--strict-light]
CAPTURE: a recording made by tools/world_import/capture_area.py (vanilla's level_chunk_with_light packets of the imported world).
DB: libpq environment or DBCRAFT_PSQL.  Exit status 0 when every compared chunk matches in every component that is required to match.
Compared per chunk: the three heightmaps, every section (counts, bit widths, palette ids, packed data, biome container), block entities (semantically:
decoded NBT, order ignored), light masks and light arrays.  Heightmap and block entity ORDER differ between vanilla runs (hash-map order) and are not compared.
"""
import argparse, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "world_import"))
import _capture as C
import anvil as A

ap = argparse.ArgumentParser()
ap.add_argument("capture")
ap.add_argument("--dimension", default="minecraft:overworld")
ap.add_argument("--examples", type=int, default=3)
ap.add_argument("--strict-light", action="store_true", help="light mismatches fail the run (default: reported only: see docs/WORLD-IMPORT.md)")
ap.add_argument("--exclude-near", default="", metavar="'X,Z;X,Z;...'",
                help="block coordinates where the probe stood: chunks within --radius of them are skipped (vanilla ticks them while the probe is there)")
ap.add_argument("--radius", type=int, default=4)
ap.add_argument("--json", help="write the lists of differing chunks per component to this file")
a = ap.parse_args()
EXCL = [(int(p.split(",")[0]) // 16, int(p.split(",")[1]) // 16) for p in a.exclude_near.split(";") if p.strip()]
PSQL = os.environ.get("DBCRAFT_PSQL", "psql").split()


def psql(sql):
    p = subprocess.run(PSQL + ["-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True)
    if p.returncode:
        sys.exit(p.stderr.decode())
    return p.stdout.decode()


vanilla = {}
for rec, b in C.packets(a.capture, "minecraft:level_chunk_with_light"):
    c = C.parse_chunk(b)
    vanilla[(c["cx"], c["cz"])] = (b, c)
have = {tuple(int(v) for v in l.split("\t")) for l in psql("select cx, cz from mc.chunk where dimension = '%s'" % a.dimension).splitlines()}
common = sorted(k for k in set(vanilla) & have if not any(max(abs(k[0] - e[0]), abs(k[1] - e[1])) <= a.radius for e in EXCL))
print("vanilla sent %d distinct chunks; dbcraft has %d; compared: %d (excluded near the probe: %d)"
      % (len(vanilla), len(have), len(common), len(set(vanilla) & have) - len(common)))
if not common:
    sys.exit("nothing to compare")

fails = {"heightmaps": [], "sections": [], "block_entities": [], "light_masks": [], "light_arrays": [], "unparsable": []}
details = {"section_fields": {}, "be_types": {}}
import json
BE_NAME = {i["protocol_id"]: n for n, i in json.load(open(os.path.join(os.environ.get("DBCRAFT_REPORTS", C.DEFAULT_REPORTS), "registries.json")))["minecraft:block_entity_type"]["entries"].items()}
n_ok = 0
batch = 40
for i in range(0, len(common), batch):
    part = common[i:i + batch]
    vals = ",".join("(%d,%d)" % xz for xz in part)
    rows = psql("select v.x, v.z, encode(mc.chunk_packet('%s', v.x, v.z), 'hex') from (values %s) v(x, z)" % (a.dimension, vals)).splitlines()
    for line in rows:
        x, z, hx = line.split("\t")
        key = (int(x), int(z))
        vb, vc = vanilla[key]
        try:
            ob = bytes.fromhex(hx)
            oc = C.parse_chunk(ob)
        except Exception as e:                                            # a packet we cannot even parse
            fails["unparsable"].append((key, repr(e)[:100]))
            continue
        ok = True
        vh = {k: raw for k, _, raw in vc["hms"]}
        oh = {k: raw for k, _, raw in oc["hms"]}
        if vh != oh:
            fails["heightmaps"].append(key); ok = False
        if len(vc["secs"]) != len(oc["secs"]) or any(vs != os_ for vs, os_ in zip(vc["secs"], oc["secs"])):
            fails["sections"].append(key); ok = False
            for idx, (vs, os_) in enumerate(zip(vc["secs"], oc["secs"])):
                for f in vs:
                    if vs[f] != os_[f]:
                        details["section_fields"].setdefault(f, []).append((key, idx))
        def be_set(c):
            s = []
            for e in c["bes"]:
                tag = None if e["nbt"] == b"\x00" else A.parse_nbt(e["nbt"], network=True)[1]
                s.append((e["packed"], e["y"], e["type"], repr(sorted(tag.items(), key=lambda kv: kv[0])) if tag is not None else None))
            return sorted(s, key=repr)
        vs, os2 = be_set(vc), be_set(oc)
        if vs != os2:
            fails["block_entities"].append(key); ok = False
            for ent in set(map(repr, vs)) ^ set(map(repr, os2)):
                t = BE_NAME.get(eval(ent)[2], eval(ent)[2])
                details["be_types"][t] = details["be_types"].get(t, 0) + 1
        if vc["masks"] != oc["masks"]:
            fails["light_masks"].append(key); ok = False
        elif vc["sky"] != oc["sky"] or vc["blk"] != oc["blk"]:
            fails["light_arrays"].append(key); ok = False
        n_ok += ok
print("chunks identical in every component: %d of %d" % (n_ok, len(common)))
required = ["unparsable", "heightmaps", "sections", "block_entities"] + (["light_masks", "light_arrays"] if a.strict_light else [])
for k, v in fails.items():
    tag = "REQUIRED" if k in required else "reported"
    print("  %-15s differing chunks: %5d  (%s)%s" % (k, len(v), tag, ("  e.g. " + ", ".join(str(x) for x in v[:a.examples])) if v else ""))
if details["be_types"]:
    print("    block entity entries that differ, by type:", details["be_types"])
for f, lst in details["section_fields"].items():
    print("    section field %-6s differs in %5d sections, e.g. %s" % (f, len(lst), lst[:3]))
if a.json:
    import json as _json
    with open(a.json, "w") as f:
        _json.dump({"compared": common, "fails": {k: [list(x[0]) if isinstance(x[0], tuple) else list(x) for x in v] for k, v in fails.items()}}, f)
bad = sum(len(fails[k]) for k in required)
print("RESULT:", "PASS" if bad == 0 else "FAIL (%d required mismatches)" % bad)
sys.exit(1 if bad else 0)
