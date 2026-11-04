#!/usr/bin/env python3
"""Show the scalar keys of the results of one scenario: usage keys.py FILE SCENARIO [TAG]"""
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["scenario"] != sys.argv[2] or (len(sys.argv) > 3 and r.get("tag") != sys.argv[3]):
        continue
    x = r.get("result", {})
    print(r["server"], r["n"], "rep", r["rep"], "load", r["load_before"]["load1"], r.get("error", ""))
    for k, v in x.items():
        if isinstance(v, list) and len(v) > 12:
            v = "[%d items]" % len(v)
        s = json.dumps(v)
        print("   %s = %s" % (k, s[:200]))
    break
