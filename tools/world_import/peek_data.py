#!/usr/bin/env python3
"""Print the small gzip-NBT files of a 26.3 world (data/minecraft/*.dat): seed, clocks, weather, game rules.  usage: peek_data.py WORLD_DIR"""
import gzip, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import anvil as A

w = sys.argv[1]
for name in ("world_gen_settings", "world_clocks", "weather", "game_rules", "world_border", "random_sequences"):
    for base in (os.path.join(w, "data", "minecraft"), os.path.join(w, "dimensions", "minecraft", "overworld", "data", "minecraft")):
        p = os.path.join(base, name + ".dat")
        if os.path.exists(p):
            with open(p, "rb") as f:
                n, v = A.parse_nbt(gzip.decompress(f.read()))
            s = repr({k: (x if not isinstance(x, (list, dict)) or len(repr(x)) < 300 else "...%d..." % len(x)) for k, x in v.items()})
            print(name, "->", s[:900])
            if name in ("world_gen_settings", "game_rules") and isinstance(v.get("data"), dict):
                print("   data keys:", {k: (x if not isinstance(x, (dict, list)) else type(x).__name__ + str(len(x))) for k, x in list(v["data"].items())[:12]})
