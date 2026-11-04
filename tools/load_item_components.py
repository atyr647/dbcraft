#!/usr/bin/env python3
"""Load the per-item data components of the official data generator (reports/minecraft/components/item/*.json) into ref.item_info and ref.item_attr.

usage: tools/load_item_components.py [DIR]      (default: $DBCRAFT_REPORTS/item_components, copied there by tools/bootstrap.sh)
Connection: standard libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE), or DBCRAFT_PSQL.
What is kept: the attribute modifiers (armor, attack speed, ...) that a worn or held item adds to a player, the slot an item equips to, and the maximum stack size:
the player-visibility layer (docs/PLAYER-VISIBILITY.md) sends them to the players who see a player as `update_attributes` / `set_equipment`.  Mojang's data: read
from your own generator output, never committed.
"""
import json, os, subprocess, sys

DEFAULT = os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "reports")
d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("DBCRAFT_REPORTS", DEFAULT), "item_components")
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()

if not os.path.isdir(d):
    sys.exit(f"no item components in {d} (tools/bootstrap.sh copies them from the generator output)")

def esc(v):
    return r"\N" if v is None else str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

def run(sql, data=None):
    p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql], input=data, capture_output=True)
    if p.returncode:
        sys.exit(f"{sql[:60]} failed:\n{p.stderr.decode()}")

info, attr = [], []
for fn in sorted(os.listdir(d)):
    if not fn.endswith(".json"):
        continue
    item = "minecraft:" + fn[:-5]
    c = json.load(open(os.path.join(d, fn)))["components"]
    eq = c.get("minecraft:equippable", {}).get("slot")
    info.append((item, eq, c.get("minecraft:max_stack_size"), json.dumps(c.get("minecraft:attack_animation", {}), sort_keys=True)))
    for i, m in enumerate(c.get("minecraft:attribute_modifiers", [])):
        attr.append((item, i, m["slot"], m["type"], m["amount"], m["operation"], m["id"]))

run("TRUNCATE ref.item_info, ref.item_attr")
run("COPY ref.item_info (item, equip_slot, max_stack, attack_animation) FROM STDIN", "".join("\t".join(esc(c) for c in r) + "\n" for r in info).encode())
run("COPY ref.item_attr (item, ord, slot, attribute, amount, op, mod_id) FROM STDIN", "".join("\t".join(esc(c) for c in r) + "\n" for r in attr).encode())
run("ANALYZE ref.item_info, ref.item_attr")
print(f"loaded {len(info)} items, {len(attr)} attribute modifiers from {d}")
