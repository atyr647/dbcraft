#!/usr/bin/env python3
"""Load item rules and recipes of the pinned vanilla jar into ref.item_def / ref.ingredient / ref.recipe / ref.recipe_slot (sql/860, sql/861).

usage: tools/load_recipes.py [--check]
Connection: libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE) or DBCRAFT_PSQL.  Needs ref.registry (tools/load_reports.py) and the item tags
(tools/load_datapack.py) first: ingredients that name a tag (#minecraft:planks) are expanded to their members here, exactly as vanilla resolves them.

Where the data comes from (all of it Mojang's, read from YOUR copy of the jar and never committed):
  * data/minecraft/recipe/**/*.json of the inner server jar (META-INF/versions/<v>/server-<v>.jar of $DBCRAFT_SERVER_JAR): shaped, shapeless, transmute,
    smelting, blasting, smoking, campfire cooking and stonecutting recipes, verbatim;
  * the default data components of every item (max_stack_size, equippable slot, cooking fuel, damage): the output of the official data generator
    (`--reports`, directory minecraft/components/item).  tools/bootstrap.sh keeps it in $DBCRAFT_REPORTS/item_components; when that is missing this script
    runs the generator once (needs Java 25) and keeps the output there;
  * the fuel burn times: data/minecraft/context_int_provider/cooking/*.json of the same jar (the 26.x cooking_fuel component names a provider: 'N / divisor');
  * crafting remainders (a water bucket leaves a bucket in the grid): Item.Properties.craftRemainder(..) calls in net.minecraft.world.item.Items, read with javap
    from the same jar (the class is only read, never run).
"""
import glob, io, json, os, re, subprocess, sys, tempfile, zipfile

psql = os.environ.get("DBCRAFT_PSQL", "psql").split()
HOME = os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft"))
REPORTS = os.environ.get("DBCRAFT_REPORTS", os.path.join(HOME, "reports"))
JAR = os.environ.get("DBCRAFT_SERVER_JAR", os.path.join(HOME, "server-26.3.jar"))
CHECK = "--check" in sys.argv


def sh(sql, data=None):
    p = subprocess.run(psql + ["-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql], input=data, capture_output=True)
    if p.returncode:
        sys.exit(f"psql failed: {p.stderr.decode()}\nSQL: {sql[:200]}")
    return p.stdout.decode()


def esc(v):
    if v is None:
        return r"\N"
    if isinstance(v, bool):
        return "t" if v else "f"
    if isinstance(v, (list, tuple)):      # a Postgres text[] literal
        return "{" + ",".join('"' + str(x).replace("\\", "\\\\").replace('"', '\\"') + '"' for x in v) + "}"
    return str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def copy(table, cols, rows):
    sh(f"COPY {table} ({','.join(cols)}) FROM STDIN", "".join("\t".join(esc(c) for c in r) + "\n" for r in rows).encode())


def inner_jar():
    outer = zipfile.ZipFile(JAR)
    names = [n for n in outer.namelist() if re.match(r"META-INF/versions/[^/]+/server-[^/]+\.jar$", n)]
    if not names:
        return outer
    return zipfile.ZipFile(io.BytesIO(outer.read(names[0])))


def item_components():
    d = os.path.join(REPORTS, "item_components")
    if not os.path.isdir(d) or not glob.glob(os.path.join(d, "*.json")):
        java = os.environ.get("JAVA") or "/usr/lib/jvm/java-25-openjdk-amd64/bin/java"
        tmp = tempfile.mkdtemp(prefix="dbcraft-gen-", dir=HOME if os.path.isdir(HOME) else None)
        print(f"running the official data generator once for the item components ({tmp}) ...", file=sys.stderr)
        r = subprocess.run([java, "-DbundlerMainClass=net.minecraft.data.Main", "-jar", JAR, "--reports", "--output", tmp], capture_output=True, text=True, cwd=tmp)   # (the bundler unpacks libraries/ and versions/ into its working directory)
        src = os.path.join(tmp, "reports", "minecraft", "components", "item")
        if r.returncode or not os.path.isdir(src):
            sys.exit("the data generator failed:\n" + r.stdout[-2000:] + r.stderr[-2000:])
        os.makedirs(d, exist_ok=True)
        for f in glob.glob(os.path.join(src, "*.json")):
            with open(f, "rb") as a, open(os.path.join(d, os.path.basename(f)), "wb") as b:
                b.write(a.read())
        subprocess.run(["rm", "-rf", tmp])
    out = {}
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        out["minecraft:" + os.path.basename(f)[:-5]] = json.load(open(f))["components"]
    return out


def providers(jar):
    """context_int_provider cooking/time_*: 'N / (fast ? 2 : 1)'  ->  (N, fast factor, normal factor)"""
    def rd(path):
        return json.loads(jar.read(path))
    base = "data/minecraft/context_int_provider/cooking/"
    fast, norm = rd(base + "fast_burn_time_reduction_factor.json"), rd(base + "normal_burn_time_reduction_factor.json")
    out = {}
    for n in jar.namelist():
        if n.startswith(base + "time_") and n.endswith(".json"):
            j = rd(n)
            assert j["type"] == "minecraft:div" and isinstance(j["left"], int), (n, j)
            out["minecraft:cooking/" + os.path.basename(n)[:-5]] = j["left"] // norm      # burn time in an ordinary furnace
            assert j["right"]["on_false"] == "minecraft:cooking/normal_burn_time_reduction_factor" and fast == 2 and norm == 1
    return out


# What javap reads from Items.<clinit> (Item.Properties.craftRemainder(..)) in the pinned jar; used when javap (a JDK; the setup image has only a JRE) is not available.
# With javap present the bytecode is read and compared with this table.
KNOWN_REMAINDERS = {"minecraft:water_bucket": "minecraft:bucket", "minecraft:lava_bucket": "minecraft:bucket", "minecraft:milk_bucket": "minecraft:bucket",
                    "minecraft:dragon_breath": "minecraft:glass_bottle", "minecraft:honey_bottle": "minecraft:glass_bottle"}


def remainders():
    """craftRemainder(...) in Items.<clinit>: registered id -> remainder item"""
    import shutil
    if not shutil.which("javap"):
        print("javap not found: using the crafting remainders recorded from the bytecode (water, lava and milk bucket -> bucket, dragon breath and honey bottle -> glass bottle)", file=sys.stderr)
        return dict(KNOWN_REMAINDERS)
    root = tempfile.mkdtemp(prefix="dbcraft-cls-")
    jar = inner_jar()
    for n in jar.namelist():
        if n.startswith("net/minecraft/world/item/Items") and n.endswith(".class"):
            jar.extract(n, root)
    out = subprocess.run(["javap", "-p", "-c", "-constants", "-classpath", root, "net.minecraft.world.item.Items"], capture_output=True, text=True,
                         env=dict(os.environ, JAVA_TOOL_OPTIONS="")).stdout
    subprocess.run(["rm", "-rf", root])
    cur, last_item, res = None, None, {}
    for l in out.splitlines():
        m = re.search(r"getstatic\s+#\d+\s+// Field net/minecraft/references/(?:Block)?ItemIds\.(\w+):", l)
        if m:
            cur = m.group(1).lower()
        m = re.search(r"getstatic\s+#\d+\s+// Field (\w+):Lnet/minecraft/world/item/Item;", l)
        if m:
            last_item = m.group(1).lower()
        if "Item$Properties.craftRemainder:" in l and cur and last_item:
            res["minecraft:" + cur] = "minecraft:" + last_item
    if res != KNOWN_REMAINDERS:
        print(f"WARNING: the crafting remainders in this jar differ from the recorded table: {res}", file=sys.stderr)
    return res


def main():
    jar = inner_jar()
    comps = item_components()
    prov = providers(jar)
    rem = remainders()
    items = {r.split("\t")[1]: int(r.split("\t")[0]) for r in sh("select protocol_id, name from ref.registry where registry = 'minecraft:item'").splitlines()}
    if not items:
        sys.exit("ref.registry has no items: run tools/load_reports.py first")
    tags = {}
    for r in sh("select tag, member from ref.dp_tag_member where registry = 'minecraft:item' order by tag, ord").splitlines():
        t, m = r.split("\t")
        tags.setdefault(t, []).append(m)
    if not tags:
        sys.exit("ref.dp_tag_member has no item tags: run tools/load_datapack.py first")

    # ---- items
    rows = []
    for name in sorted(items, key=items.get):
        c = comps.get(name)
        if c is None:
            sys.exit(f"no default components for {name}: the generator output is incomplete")
        eq = c.get("minecraft:equippable")
        slot = None
        if eq and eq.get("allowed_entities") is None:           # a slot the PLAYER can use (null = every entity)
            slot = eq["slot"]
        fuel = None
        if "minecraft:cooking_fuel" in c:
            fuel = prov[c["minecraft:cooking_fuel"]["burn_time"]]
        ur = c.get("minecraft:use_remainder", {}).get("id")
        rows.append((name, c.get("minecraft:max_stack_size", 64), c.get("minecraft:max_damage"), slot, rem.get(name), fuel, ur))
    # ---- ingredients, recipes
    ing_ids, ing_rows = {}, []

    def ingredient(v):
        if isinstance(v, str):
            v = [v]
        members = []
        for e in v:
            if e.startswith("#"):
                t = e[1:] if ":" in e else "minecraft:" + e[1:]
                if t not in tags:
                    sys.exit(f"unknown item tag {e}")
                members += tags[t]
            else:
                if e not in items:
                    sys.exit(f"unknown item {e} in a recipe")
                members.append(e)
        key = tuple(sorted(set(members), key=items.get))
        if key not in ing_ids:
            ing_ids[key] = len(ing_ids) + 1
            ing_rows.append((ing_ids[key], list(key)))
        return ing_ids[key]

    recipes, slots = [], []
    skipped = {}
    for n in sorted(jar.namelist()):
        if not (n.startswith("data/minecraft/recipe/") and n.endswith(".json")):
            continue
        rid = "minecraft:" + n[len("data/minecraft/recipe/"):-5]
        j = json.loads(jar.read(n))
        t = j["type"].replace("minecraft:", "")
        res = j.get("result")
        if isinstance(res, dict) and ("components" in res or "id" not in res or isinstance(j.get("material_count"), dict)):
            skipped[t + " (result with components or a count range)"] = skipped.get(t + " (result with components or a count range)", 0) + 1
            continue
        if t == "crafting_shaped":
            pat = j["pattern"]
            h, w = len(pat), len(pat[0])
            cnt = 0
            for y, line in enumerate(pat):
                for x, ch in enumerate(line):
                    if ch != " ":
                        slots.append((rid, y * w + x, ingredient(j["key"][ch]))); cnt += 1
            recipes.append((rid, t, j.get("category"), j.get("group"), res["id"], res.get("count", 1), w, h, cnt, None, None, None, None))
        elif t == "crafting_shapeless":
            for i, e in enumerate(j["ingredients"]):
                slots.append((rid, i, ingredient(e)))
            recipes.append((rid, t, j.get("category"), j.get("group"), res["id"], res.get("count", 1), None, None, len(j["ingredients"]), None, None, None, None))
        elif t == "crafting_transmute":
            slots.append((rid, 0, ingredient(j["input"])))
            mc = j.get("material_count", 1)
            for i in range(mc):
                slots.append((rid, 1 + i, ingredient(j["material"])))
            recipes.append((rid, t, j.get("category"), j.get("group"), res["id"], res.get("count", 1), None, None, 1 + mc, None, None, None,
                            bool(j.get("add_material_count_to_result", False))))
        elif t in ("smelting", "blasting", "smoking", "campfire_cooking"):
            recipes.append((rid, t, j.get("category"), j.get("group"), res["id"], res.get("count", 1), None, None, 1, ingredient(j["ingredient"]),
                            j.get("cookingtime", 200), j.get("experience", 0), None))
        elif t == "stonecutting":
            recipes.append((rid, t, None, None, res["id"], res.get("count", 1), None, None, 1, ingredient(j["ingredient"]), None, None, None))
        else:
            skipped[t] = skipped.get(t, 0) + 1
    if CHECK:
        print(f"{len(rows)} items, {len(recipes)} recipes, {len(ing_rows)} ingredients, skipped: {skipped}")
        return
    sh("truncate ref.recipe_slot, ref.recipe, ref.ingredient, ref.item_def")
    copy("ref.item_def", ["item", "max_stack", "max_damage", "equip_slot", "remainder", "burn_ticks", "use_remainder"], rows)
    copy("ref.ingredient", ["id", "items"], ing_rows)
    copy("ref.recipe", ["id", "type", "category", "grp", "result_item", "result_count", "w", "h", "n_ingredients", "ingredient", "cookingtime", "experience", "flag"], recipes)
    copy("ref.recipe_slot", ["recipe", "pos", "ingredient"], slots)
    sh("analyze ref.recipe, ref.recipe_slot, ref.ingredient, ref.item_def")
    sh("do $$ begin if to_regprocedure('mc.recipes_refresh()') is not null then perform mc.recipes_refresh(); end if; end $$")
    print(f"loaded {len(rows)} items, {len(recipes)} recipes ({len(slots)} ingredient slots, {len(ing_rows)} distinct ingredients); not loaded: {skipped}")


main()
