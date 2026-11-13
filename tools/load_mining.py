#!/usr/bin/env python3
"""Load what digging needs into ref.block_mining / ref.item_tool / ref.item_tool_rule / ref.item_tool_block / ref.block_loot.

  * tools/gen_mining.sh -> $DBCRAFT_REPORTS/block_mining.tsv (hardness and "requires the correct tool for drops" per block, read from the game itself) and
    $DBCRAFT_REPORTS/loot_blocks/*.json (the block loot tables of the jar);
  * $DBCRAFT_REPORTS/item_components/*.json (the data generator's per-item components): the `minecraft:tool` component (rules, default speed, damage per block, whether the
    item may break blocks in creative) and `minecraft:max_damage`;
  * the block tags a tool rule names (`#minecraft:mineable/pickaxe`, `#minecraft:incorrect_for_iron_tool` ...) come from ref.dp_tag_member (tools/load_datapack.py must have run
    first); they are expanded into ref.item_tool_block, one row per (item, rule, block), so the lookup at dig time is a primary-key probe.

usage: tools/load_mining.py [REPORTS_DIR]      connection: the libpq environment, or DBCRAFT_PSQL.  Exits 0 without doing anything when block_mining.tsv does not exist.
"""
import json, os, subprocess, sys

HOME = os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft"))
rep = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DBCRAFT_REPORTS", os.path.join(HOME, "reports"))
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()
tsv = os.path.join(rep, "block_mining.tsv")
if not os.path.exists(tsv):
    print(f"no {tsv}: no mining data (run tools/gen_mining.sh)")
    sys.exit(0)

def esc(v):
    return r"\N" if v is None else str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

def run(sql, data=None):
    p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql], input=data, capture_output=True)
    if p.returncode:
        sys.exit(f"{sql[:60]} failed:\n{p.stderr.decode()}")

B, O = [], []
for line in open(tsv):
    c = line.rstrip("\n").split("\t")
    if c[0] == "B": B.append((c[1], c[2], "t" if c[3] == "1" else "f"))
    elif c[0] == "O": O.append(c[1:])
if O:
    print("NOTE: block classes override getDestroyProgress:", O[:5], file=sys.stderr)

tools, rules = [], []
d = os.path.join(rep, "item_components")
if os.path.isdir(d):
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        item = "minecraft:" + fn[:-5]
        comp = json.load(open(os.path.join(d, fn)))["components"]
        t = comp.get("minecraft:tool")
        if t is None:
            continue
        tools.append((item, t.get("default_mining_speed", 1.0), t.get("damage_per_block", 1), "t" if t.get("can_destroy_blocks_in_creative", True) else "f", comp.get("minecraft:max_damage")))
        for i, r in enumerate(t.get("rules", [])):
            bl = r["blocks"]
            for b in (bl if isinstance(bl, list) else [bl]):
                rules.append((item, i, b, r.get("speed"), None if "correct_for_drops" not in r else ("t" if r["correct_for_drops"] else "f")))
else:
    print(f"NOTE: no {d}: no tool data (tools/bootstrap.sh copies it); every item digs like a hand")

loot = []
ld = os.path.join(rep, "loot_blocks")
if os.path.isdir(ld):
    for fn in sorted(os.listdir(ld)):
        if fn.endswith(".json"):
            loot.append(("minecraft:" + fn[:-5], json.dumps(json.load(open(os.path.join(ld, fn))), separators=(",", ":"))))
else:
    print(f"NOTE: no {ld}: broken blocks drop nothing (tools/gen_mining.sh copies the loot tables)")

def tab(rows):
    return "".join("\t".join(esc(c) for c in r) + "\n" for r in rows).encode()

run("TRUNCATE ref.block_mining, ref.item_tool, ref.item_tool_rule, ref.item_tool_block, ref.block_loot")
run("COPY ref.block_mining (block, hardness, requires_tool) FROM STDIN", tab(B))
run("COPY ref.item_tool (item, default_speed, damage_per_block, creative_ok, max_damage) FROM STDIN", tab(tools))
run("COPY ref.item_tool_rule (item, ord, spec, speed, correct) FROM STDIN", tab(rules))
run("COPY ref.block_loot (block, loot) FROM STDIN", tab(loot))
run("SELECT ref.item_tool_expand()")
run("ANALYZE ref.block_mining, ref.item_tool, ref.item_tool_block, ref.block_loot")
print(f"loaded {len(B)} blocks, {len(tools)} tools with {len(rules)} rules, {len(loot)} loot tables from {rep}")
