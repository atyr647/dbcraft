#!/usr/bin/env python3
"""Load the block sound types (tools/gen_sounds.sh -> $DBCRAFT_REPORTS/block_sounds.tsv) into mc.sound_type / mc.block_sound / mc.block_sound_x.  Run after
tools/load_reports.py (the sound events' ids come from the registry rows).  Without the file the server sends no block sounds (the other sounds do not need it).

usage: tools/load_sounds.py [FILE]       connection: the libpq environment, or DBCRAFT_PSQL.  Exits 0 without doing anything when the file does not exist.
"""
import os, subprocess, sys

DEFAULT = os.path.join(os.environ.get("DBCRAFT_REPORTS", os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")), "block_sounds.tsv")
path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()
if not os.path.exists(path):
    print(f"no {path}: no block sounds (run tools/gen_sounds.sh)")
    sys.exit(0)
T, B, X = [], [], []
with open(path) as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if c[0] == "T": T.append(c[1:])
        elif c[0] == "B": B.append(c[1:])
        elif c[0] == "X": X.append(c[1:])
script = ("truncate mc.sound_type, mc.block_sound, mc.block_sound_x;\n"
          "copy mc.sound_type (id, volume, pitch, break_snd, step_snd, place_snd, hit_snd, fall_snd) from stdin;\n" + "".join("\t".join(r) + "\n" for r in T) + "\\.\n"
          "copy mc.block_sound (block, type) from stdin;\n" + "".join("\t".join(r) + "\n" for r in B) + "\\.\n"
          "copy mc.block_sound_x (state_id, type) from stdin;\n" + "".join("\t".join(r) + "\n" for r in X) + "\\.\n"
          "analyze mc.block_sound;\n")
p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1"], input=script.encode(), capture_output=True)
if p.returncode:
    sys.exit(p.stderr.decode())
print(f"loaded {len(T)} sound types, {len(B)} blocks, {len(X)} state exceptions from {path}")
