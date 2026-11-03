#!/usr/bin/env bash
# Compare mc.shortset_order (sql/850) with the real fastutil ShortOpenHashSet that vanilla 26.3 uses for the changed positions of a section.
#   tests/bench/world/set_order.sh [DATABASE]          (libpq environment variables select the server; default database dbcraft)
# Runs 100+ insertion sequences (random with duplicates, distinct, ascending from 0, the sizes around every rehash threshold 24/25, 48/49, ... 3072/3073, the /fill
# orders of boxes and of a whole section) through Java and through the SQL function and reports the number of differences (expected: 0).  With --vectors it prints the
# md5 values that tests/sql/851_section_updates.sql pins (so the test file can be regenerated).
# Needs: Java 11+ (`java`, or JAVA=...), and the fastutil jar of the vanilla server: FASTUTIL=/path/fastutil-8.5.18.jar (default: under $DBCRAFT_HOME/vanilla/libraries,
# which `tools/bootstrap.sh` creates by running the server once).
set -euo pipefail
cd "$(dirname "$0")/../../.."
. tools/env.sh
FASTUTIL=${FASTUTIL:-$(ls "$DBCRAFT_HOME"/vanilla/libraries/it/unimi/dsi/fastutil/*/fastutil-*.jar 2>/dev/null | head -1)}
[ -f "$FASTUTIL" ] || { echo "fastutil jar not found (set FASTUTIL=...)" >&2; exit 2; }
JAVA=${JAVA:-java}
exec python3 - "${1:-dbcraft}" "$FASTUTIL" "$JAVA" "${2:-}" <<'PY'
import random, subprocess, sys
db, jar, java, mode = sys.argv[1:5]
rnd = random.Random(1234)
cases = []
for n in [1, 2, 3, 5, 24, 25, 26, 48, 49, 50, 96, 97, 192, 193, 384, 385, 768, 769, 1536, 1537, 3072, 3073, 4000, 4096]:
    cases.append([rnd.randrange(0, 4096) for _ in range(n)])
    cases.append(rnd.sample(range(4096), n))
    cases.append(list(range(n)))
    cases.append(list(range(1, n + 1)))
def box(x1, x2, y1, y2, z1, z2):
    return [(x << 8) | (z << 4) | y for z in range(z1, z2 + 1) for y in range(y1, y2 + 1) for x in range(x1, x2 + 1)]
cases += [box(0, 15, 0, 15, 0, 15), box(0, 3, 0, 2, 0, 1), box(0, 15, 0, 6, 0, 6), box(3, 12, 2, 9, 1, 14)]
vec = {  # the inputs of tests/sql/851_section_updates.sql, in the order of its VEC1 .. VEC12 placeholders
    "VEC1": box(0, 15, 0, 15, 0, 15), "VEC2": box(0, 3, 0, 2, 0, 1),
    "VEC3": [(i * 37) % 4096 for i in range(25)], "VEC4": [(i * 37) % 4096 for i in range(49)], "VEC5": [(i * 37) % 4096 for i in range(97)],
    "VEC6": [(i * 37) % 4096 for i in range(193)], "VEC7": [(i * 37) % 4096 for i in range(385)], "VEC8": [(i * 2749 + 17) % 4096 for i in range(3000)],
    "VEC9": [(i * i * 7 + i) % 4096 for i in range(5001)], "VEC10": list(range(100)), "VEC11": [4, 260], "VEC12": [7, 7, 7]}
allc = cases + list(vec.values())
inp = "\n".join(",".join(map(str, c)) for c in allc) + "\n"
jv = subprocess.run([java, "-cp", jar, "tests/bench/world/SetOrder.java"], input=inp, capture_output=True, text=True)
if jv.returncode:
    print(jv.stderr); sys.exit(1)
out = jv.stdout.strip("\n").split("\n")
if mode == "--vectors":
    import hashlib
    for (k, _), line in zip(vec.items(), out[len(cases):]):
        print(k, hashlib.md5(line.encode()).hexdigest())
    sys.exit(0)
bad = 0
for c, j in zip(cases, out):
    r = subprocess.run(["psql", "-X", "-At", "-d", db, "-c", "select array_to_string(mc.shortset_order(array[%s]), ',')" % ",".join(map(str, c))], capture_output=True, text=True)
    if r.stdout.strip() != j:
        bad += 1
        print("DIFF n=%d first=%s %s" % (len(c), c[:5], r.stderr[:200]))
print("%d sequences through fastutil and mc.shortset_order, %d differ" % (len(cases), bad))
sys.exit(1 if bad else 0)
PY
