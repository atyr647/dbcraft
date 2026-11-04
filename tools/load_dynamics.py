#!/usr/bin/env python3
"""Load the world-dynamics reference data (tools/gen_dynamics.sh -> $DBCRAFT_REPORTS/dyn_states.tsv) into mc.dyn_state / mc.dyn_shape / mc.dyn_occlude and build the
arrays the engine reads (mc.dyn_rebuild).  Run after tools/load_reports.py (it needs ref.dp_tag_member for the 'washed away by fluids' tag; run tools/load_datapack.py first).

usage: tools/load_dynamics.py [FILE]       connection: the libpq environment, or DBCRAFT_PSQL.  Exits 0 without doing anything when the file does not exist.
"""
import os, subprocess, sys

DEFAULT = os.path.join(os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")), "dyn_states.tsv")
path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()
if not os.path.exists(path):
    print(f"no {path}: world dynamics stay disabled (run tools/gen_dynamics.sh)")
    sys.exit(0)

def esc(v):
    return v.replace("\\", "\\\\")

states, shapes, occ = [], [], []
with open(path) as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if c[0] == "S":
            # S sid block chain rtick air solid occludes blocks_motion fluid famount ffall wl coll sf sc sr lbc repl
            sid, block, chain = c[1], c[2], c[3]
            states.append((sid, block, chain, c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12], c[13], c[14], c[15], c[16], c[17], c[18], c[19]))
        elif c[0] == "H":
            shapes.append((c[1], c[2], c[3]))
        elif c[0] == "O":
            occ.append((c[1], c[2], c[3]))

# state names come from ref.block_state (the loader of the generator reports): one source of truth for the spelling
# one psql session: temp table + copy + insert must share the connection
script = ("create temp table dyn_in (sid int, block text, chain text, rtick text, air text, solid text, occl text, bm text, fluid text, famount int, ffall text, wl text, coll int, sf text, sc text, sr text, lbc text, repl text, lightd int);\n"
          "copy dyn_in from stdin;\n" + "".join("\t".join(esc(x) for x in r) + "\n" for r in states) + "\\.\n"
          "truncate mc.dyn_state, mc.dyn_shape, mc.dyn_occlude;\n"
          "insert into mc.dyn_state (sid, name, block, chain, rtick, air, solid, occludes, blocks_motion, fluid, famount, ffall, wl, coll, sf, sc, sr, lbc, repl, lightd)\n"
          "select i.sid, b.name, i.block, i.chain, i.rtick = 't', i.air = 't', i.solid = 't', i.occl = 't', i.bm = 't', i.fluid, i.famount, i.ffall = 't', i.wl = 't', i.coll, i.sf, i.sc, i.sr, i.lbc = 't', i.repl = 't', i.lightd\n"
          "  from dyn_in i join ref.block_state b on b.state_id = i.sid;\n"
          "copy mc.dyn_shape (id, kind, aabbs) from stdin;\n" + "".join("\t".join(esc(x) for x in r) + "\n" for r in shapes) + "\\.\n"
          "copy mc.dyn_occlude (from_shape, to_shape, dir) from stdin;\n" + "".join("\t".join(r) + "\n" for r in occ) + "\\.\n"
          "select mc.dyn_rebuild();\nanalyze mc.dyn_state;\n")
p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1"], input=script.encode(), capture_output=True)
if p.returncode:
    sys.exit(p.stderr.decode())
print(f"loaded {len(states)} block states, {len(shapes)} collision shapes, {len(occ)} occluding pairs from {path}")
