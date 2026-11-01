#!/usr/bin/env python3
"""Load the Minecraft data generator's reports into the ref.* tables.

usage: tools/load_reports.py [REPORT_DIR]      (default: $DBCRAFT_REPORTS, else the adacraft checkout)
Connection: standard libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE), or `tools/pg-dev.sh psql` settings via DBCRAFT_PSQL.
The reports are Mojang's generated data; they are read from your own generator output and are never committed to this repository.
"""
import json, os, subprocess, sys

DEFAULT = "/home/user/atyr647/adacraft/generated/26.3/reports"
report_dir = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DBCRAFT_REPORTS", DEFAULT)
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()

def esc(v):
    return r"\N" if v is None else str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

def copy(table, cols, rows):
    sql = f"COPY {table} ({','.join(cols)}) FROM STDIN"
    p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       input="".join("\t".join(esc(c) for c in r) + "\n" for r in rows).encode(),
                       capture_output=True)
    if p.returncode:
        sys.exit(f"COPY {table} failed:\n{p.stderr.decode()}")

def run(sql):
    p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True)
    if p.returncode:
        sys.exit(p.stderr.decode())

def load(name):
    with open(os.path.join(report_dir, name)) as f:
        return json.load(f)

run("TRUNCATE ref.block_state, ref.block, ref.registry, ref.packet")

blocks = load("blocks.json")
brow, srow = [], []
for bname, b in blocks.items():
    props = b.get("properties", {})
    default = next(s["id"] for s in b["states"] if s.get("default"))
    brow.append((bname, default, json.dumps(props)))
    for s in b["states"]:
        sp = s.get("properties", {})
        label = bname + ("[" + ",".join(f"{k}={v}" for k, v in sp.items()) + "]" if sp else "")
        srow.append((s["id"], bname, json.dumps(sp), "t" if s.get("default") else "f", label))
copy("ref.block", ["name", "default_state", "properties"], brow)
copy("ref.block_state", ["state_id", "block", "properties", "is_default", "name"], srow)

reg = load("registries.json")
copy("ref.registry", ["registry", "name", "protocol_id"],
     [(rn, en, e["protocol_id"]) for rn, r in reg.items() for en, e in r["entries"].items() if "protocol_id" in e])

pk = load("packets.json")
copy("ref.packet", ["state", "direction", "name", "protocol_id"],
     [(st, d, n, e["protocol_id"]) for st, dirs in pk.items() for d, ps in dirs.items() for n, e in ps.items()])

run("ANALYZE ref.block, ref.block_state, ref.registry, ref.packet")
print(f"loaded {len(brow)} blocks, {len(srow)} block states, "
      f"{sum(len(r['entries']) for r in reg.values())} registry entries, "
      f"{sum(len(ps) for dirs in pk.values() for ps in dirs.values())} packets from {report_dir}")
