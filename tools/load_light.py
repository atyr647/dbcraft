#!/usr/bin/env python3
"""Load the light-engine reference data (tools/gen_light.sh -> $DBCRAFT_REPORTS/light_states.tsv) into mc.light_state / mc.light_face / mc.light_face_occ.
Run after tools/load_reports.py (state names come from ref.block_state).  Exits 0 without doing anything when the file does not exist: the light engine then stays
disabled and mc.compute_light keeps the straight-down sky model (docs/LIGHT.md).

usage: tools/load_light.py [FILE]       connection: the libpq environment, or DBCRAFT_PSQL.
"""
import os, subprocess, sys

DEFAULT = os.path.join(os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")), "light_states.tsv")
path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()
if not os.path.exists(path):
    print(f"no {path}: the light engine stays disabled (run tools/gen_light.sh)")
    sys.exit(0)

states, faces, occ = [], [], []
with open(path) as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if c[0] == "S":
            states.append(c[1:])            # sid emission damp shaped f0..f5
        elif c[0] == "F":
            faces.append(c[1:4])
        elif c[0] == "P":
            occ.append(c[1:3])

script = ("create temp table light_in (sid int, emission int, damp int, shaped text, f0 int, f1 int, f2 int, f3 int, f4 int, f5 int);\n"
          "copy light_in from stdin;\n" + "".join("\t".join(r) + "\n" for r in states) + "\\.\n"
          "truncate mc.light_state, mc.light_face, mc.light_face_occ;\n"
          "insert into mc.light_state (sid, name, emission, damp, shaped, f_down, f_up, f_north, f_south, f_west, f_east)\n"
          "select i.sid, b.name, i.emission, i.damp, i.shaped = 't', i.f0, i.f1, i.f2, i.f3, i.f4, i.f5 from light_in i join ref.block_state b on b.state_id = i.sid;\n"
          "copy mc.light_face (id, kind, boxes) from stdin;\n" + "".join("\t".join(r) + "\n" for r in faces) + "\\.\n"
          "copy mc.light_face_occ (a, b) from stdin;\n" + "".join("\t".join(r) + "\n" for r in occ) + "\\.\n"
          "analyze mc.light_state;\n")
p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1"], input=script.encode(), capture_output=True)
if p.returncode:
    sys.exit(p.stderr.decode())
print(f"loaded {len(states)} block states, {len(faces)} face shapes, {len(occ)} occluding pairs from {path}")
