#!/usr/bin/env python3
"""Check the recipe rows (ref.recipe, loaded from the jar's data/recipe JSON by tools/load_recipes.py) against the update_recipes packet a REAL vanilla 26.3 server sent
(net.static_packet, captured by tools/capture_vanilla.py): the packet carries, per RecipePropertySet, the items the recipes accept, and the stonecutter recipes with their
input and display.  vanilla writes the sets in hash order (different in every run of the JVM: Set.copyOf), so the bytes cannot be generated, but the CONTENT can be compared:

  furnace_input / blast_furnace_input / smoker_input / campfire_input   must equal the union of the ingredients of the smelting / blasting / smoking / campfire recipes
  stonecutter entries                                                   must equal the (ingredient, result item, result count) of the stonecutting recipes

usage: tests/e2e/check_recipes_vs_capture.py          (libpq environment names the database; exit code 0 when everything is equal)
"""
import os, subprocess, sys


def psql(q):
    p = subprocess.run(os.environ.get("DBCRAFT_PSQL", "psql").split() + ["-X", "-q", "-At", "-F", "\t", "-c", q], capture_output=True, text=True)
    if p.returncode:
        sys.exit(p.stderr)
    return p.stdout.strip().splitlines()


def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 127) << s
        if not c & 128:
            return v, o
        s += 7


def rstr(b, o):
    n, o = vi(b, o)
    return b[o:o + n].decode(), o + n


raw = psql("select encode(body, 'hex') from net.static_packet where packet = 'minecraft:update_recipes'")
if not raw:
    print("SKIP no captured update_recipes packet"); sys.exit(0)
body = bytes.fromhex(raw[0])
items = {int(r.split("\t")[0]): r.split("\t")[1] for r in psql("select protocol_id, name from ref.registry where registry = 'minecraft:item'")}
o = 0
n, o = vi(body, o)
sets = {}
for _ in range(n):
    name, o = rstr(body, o)
    cnt, o = vi(body, o)
    ids = []
    for _ in range(cnt):
        i, o = vi(body, o); ids.append(items[i])
    sets[name] = ids
fails = 0


def union(types):
    q = "select distinct x from ref.recipe r join ref.ingredient i on i.id = r.ingredient, unnest(i.items) x where r.type in (%s)" % ",".join("'%s'" % t for t in types)
    return set(psql(q))


for key, types in (("minecraft:furnace_input", ["smelting"]), ("minecraft:blast_furnace_input", ["blasting"]), ("minecraft:smoker_input", ["smoking"]), ("minecraft:campfire_input", ["campfire_cooking"])):
    got, want = set(sets.get(key, [])), union(types)
    ok = got == want
    fails += not ok
    print(("OK   " if ok else "FAIL ") + f"{key}: vanilla {len(got)} items, rows {len(want)}" + ("" if ok else f"  only vanilla {sorted(got - want)[:5]}  only rows {sorted(want - got)[:5]}"))
# stonecutter: the rest of the packet.  SingleInputSet = list of (Ingredient contents, SlotDisplay)
cnt, o = vi(body, o)
entries = []
for _ in range(cnt):
    k, o = vi(body, o)                                   # holder set: 0 = a tag (not used here), else size + 1
    if k == 0:
        sys.exit("tagged ingredient in the stonecutter list: layout not understood")
    ing = []
    for _ in range(k - 1):
        i, o = vi(body, o); ing.append(items[i])
    t, o = vi(body, o)                                   # SlotDisplay type: 5 = item_stack (empty 0, any_fuel 1, with_any_potion 2, only_with_component 3, item 4, item_stack 5, tag 6 ...): ItemStackTemplate = item, count, components
    if t != 5:
        sys.exit(f"slot display type {t} not understood")
    it, o = vi(body, o); c, o = vi(body, o); a, o = vi(body, o); r, o = vi(body, o)
    if a or r:
        sys.exit("components in a stonecutter result: layout not understood")
    entries.append((tuple(sorted(ing)), items[it], c))
rows = psql("select i.items, r.result_item, r.result_count from ref.recipe r join ref.ingredient i on i.id = r.ingredient where r.type = 'stonecutting'")
want = []
for r in rows:
    its, res, c = r.split("\t")
    want.append((tuple(sorted(x.strip('"') for x in its.strip("{}").split(","))), res, int(c)))
ok = sorted(entries) == sorted(want)
fails += not ok
print(("OK   " if ok else "FAIL ") + f"stonecutter: vanilla {len(entries)} entries, rows {len(want)}" + ("" if ok else f"  only vanilla {sorted(set(entries) - set(want))[:3]}  only rows {sorted(set(want) - set(entries))[:3]}"))
print("the order of the entries in vanilla's packet:", "same as the sorted recipe ids" if [e[1] for e in entries] == [w[1] for w in sorted(want, key=lambda x: x)] else "hash order (the packet is replayed, not generated)")
sys.exit(1 if fails else 0)
