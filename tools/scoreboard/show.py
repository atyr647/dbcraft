#!/usr/bin/env python3
"""Print one line per run of a results file: usage show.py FILE [SCENARIO] -- quick look at the keys a campaign cell produced."""
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if len(sys.argv) > 2 and r["scenario"] != sys.argv[2]:
        continue
    res = r.get("result", {})
    short = {k: (round(v, 2) if isinstance(v, float) else v) for k, v in res.items()
             if isinstance(v, (int, float, bool)) or k.endswith("_stats") or k.endswith("_tick_stats")}
    print(r["scenario"], r["server"], "n=%s mov=%s rep=%s load=%.2f" % (r["n"], r["moving"], r["rep"], r["load_before"]["load1"]), r.get("error", ""), json.dumps(short)[:900])
