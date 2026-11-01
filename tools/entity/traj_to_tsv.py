#!/usr/bin/env python3
"""Print the recorded vanilla entity trajectories (tests/fixtures/captured/entity_traj_*.json, made by tools/entity/rcon.py record) as TSV:
name, tick, x, y, z, vx, vy, vz, on_ground.   Prints nothing if no recording exists (the SQL test then skips with a notice)."""
import glob, json, os, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
for path in sorted(glob.glob(os.path.join(root, "tests", "fixtures", "captured", "entity_traj_*.json"))):
    d = json.load(open(path))
    for r in d["rows"]:
        print("\t".join([d["name"], str(r["tick"]), *(repr(v) for v in r["pos"]), *(repr(v) for v in r["motion"]), "t" if r["on_ground"] else "f"]))
