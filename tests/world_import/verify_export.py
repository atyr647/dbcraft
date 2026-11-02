#!/usr/bin/env python3
"""Round-trip check of the exporter against a REAL vanilla server.

  verify_export.py prepare SAMPLES.json [--samples N] [--edits M] [--seed S]
        edits M blocks in the database (mc.set_block) and records N sampled positions (the edited ones included) with the block the database holds there.
        Run tools/world_export.py afterwards, start vanilla on the export (tools/world_import/vanilla_world.sh), then:
  verify_export.py check SAMPLES.json
        asks the running vanilla server over RCON (port 25718, password importtest) `execute if block X Y Z STATE` for every sample.
Exit status 0 when every sampled block is the same in vanilla as in the database.  DB: libpq environment or DBCRAFT_PSQL.  Standard library only."""
import json, os, random, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "entity"))
PSQL = os.environ.get("DBCRAFT_PSQL", "psql").split()
DIM = "minecraft:overworld"


def psql(sql):
    p = subprocess.run(PSQL + ["-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True)
    if p.returncode:
        sys.exit(p.stderr.decode())
    return p.stdout.decode().splitlines()


def prepare(path, n, m, seed):
    rnd = random.Random(seed)
    chunks = [tuple(int(v) for v in l.split("\t")) for l in psql("select cx, cz from mc.chunk where dimension = '%s' order by cx, cz" % DIM)]
    edit_blocks = ["minecraft:gold_block", "minecraft:diamond_block", "minecraft:oak_log[axis=x]", "minecraft:lantern[hanging=true,waterlogged=false]",
                   "minecraft:chest[type=single,facing=north,waterlogged=false]", "minecraft:redstone_block", "minecraft:glowstone", "minecraft:oak_stairs[facing=east,half=top,shape=straight,waterlogged=false]"]
    pts = []
    for i in range(n):
        cx, cz = rnd.choice(chunks)
        pts.append((cx * 16 + rnd.randrange(16), rnd.randrange(-64, 120), cz * 16 + rnd.randrange(16)))
    sql = []
    for i in range(m):                                                   # edits inside already-sampled chunks, at the sampled columns, in the air or ground
        x, y, z = pts[i]
        sql.append("select mc.set_block('%s', %d, %d, %d, '%s')" % (DIM, x, y, z, edit_blocks[i % len(edit_blocks)]))
    if sql:
        psql(";".join(sql))
    out = []
    for x, y, z in pts:
        out.append([x, y, z, psql("select mc.get_block('%s', %d, %d, %d)" % (DIM, x, y, z))[0]])
    with open(path, "w") as f:
        json.dump({"chunks": chunks, "samples": out, "edited": m}, f)
    names = {s[3] for s in out}
    print("%d samples in %d chunks, %d edits, %d distinct block states" % (len(out), len(chunks), m, len(names)))


def check(path):
    import rcon
    os.environ.setdefault("RCON_PORT", "25718")
    d = json.load(open(path))
    r = rcon.Rcon()
    r.sock.settimeout(180)
    r.cmd("tick freeze")                                                # no random ticks / fluid flow while sampling
    for cx, cz in d["chunks"]:
        r.cmd("forceload add %d %d" % (cx * 16, cz * 16))
    bad = []
    for x, y, z, st in d["samples"]:
        res = r.cmd("execute if block %d %d %d %s" % (x, y, z, st))
        if "passed" not in res:
            got = r.cmd("data get block %d %d %d" % (x, y, z))
            bad.append((x, y, z, st, res))
    print("sampled %d positions (%d edited ones) in %d chunks: %d differ" % (len(d["samples"]), d["edited"], len(d["chunks"]), len(bad)))
    for b in bad[:10]:
        print("  MISMATCH", b)
    print("RESULT:", "PASS" if not bad else "FAIL")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    a = sys.argv[1:]
    opt = lambda k, dflt: int(a[a.index(k) + 1]) if k in a else dflt
    if len(a) >= 2 and a[0] == "prepare":
        prepare(a[1], opt("--samples", 600), opt("--edits", 40), opt("--seed", 1))
    elif len(a) >= 2 and a[0] == "check":
        check(a[1])
    else:
        sys.exit(__doc__)
