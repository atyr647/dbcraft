#!/usr/bin/env python3
"""List functions defined in more than one sql/*.sql file (a later file silently replaces an earlier one).

usage: tools/check_overrides.py            exit 1 if an override is not listed in sql/OVERRIDES.txt (or a listed one no longer exists)
       tools/check_overrides.py --list     print every current override as 'schema.name  file1 file2 ...' (the last file wins)
Why: independent workers optimised the same function twice (net.stream_chunks) and the later file silently undid the earlier one; the tests re-include
single files so they cannot see that.  Every intended override must be written down with the reason in sql/OVERRIDES.txt:  name | winner file | why
"""
import glob, os, re, sys
os.chdir(os.path.join(os.path.dirname(__file__), ".."))
pat = re.compile(r"create\s+(?:or\s+replace\s+)?(?:function|procedure)\s+([a-z_][a-z_0-9]*\.[a-z_][a-z_0-9]*)\s*\(([^)]*)\)", re.I)
defs = {}
for f in sorted(glob.glob("sql/*.sql")):
    text = re.sub(r"--[^\n]*", "", open(f).read())
    seen = set()
    for m in pat.finditer(text):
        # identify by schema.name plus the argument TYPES count (overloads with different arity are different functions)
        args = [a.strip() for a in m.group(2).split(",") if a.strip()]
        key = f"{m.group(1).lower()}/{len(args)}"
        if key in seen: continue
        seen.add(key); defs.setdefault(key, []).append(os.path.basename(f))
over = {k: v for k, v in defs.items() if len(v) > 1}
if "--list" in sys.argv:
    for k, v in sorted(over.items()): print(f"{k}  {' '.join(v)}")
    sys.exit(0)
allowed = {}
if os.path.exists("sql/OVERRIDES.txt"):
    for line in open("sql/OVERRIDES.txt"):
        line = line.strip()
        if line and not line.startswith("#"):
            name, winner, *why = [p.strip() for p in line.split("|")]
            allowed[name.lower()] = (winner, " | ".join(why))
bad = 0
for k, v in sorted(over.items()):
    if k not in allowed: print(f"UNLISTED override {k}: {' -> '.join(v)}"); bad = 1
    elif allowed[k][0] != v[-1]: print(f"WRONG WINNER {k}: last definition is {v[-1]}, OVERRIDES.txt says {allowed[k][0]}"); bad = 1
for k in allowed:
    if k not in over: print(f"STALE entry in OVERRIDES.txt (no longer overridden): {k}"); bad = 1
print("overrides: %d, all listed" % len(over) if not bad else "overrides check FAILED")
sys.exit(bad)
