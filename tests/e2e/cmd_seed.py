#!/usr/bin/env python3
"""Print the world seed the real vanilla server told its operator in the recorded command session (the `seed` step of tests/e2e/cmd_steps.py): the seed of a vanilla
world is random, so the dbcraft run is given the same one (server property level-seed) and `/seed` can be compared byte for byte.

usage: tests/e2e/cmd_seed.py VANILLA_PREFIX          (the prefix of the files record_commands.sh wrote: <prefix>_Op4.jsonl)
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

cur = None
for line in open(sys.argv[1] + "_Op4.jsonl"):
    e = json.loads(line)
    if e["state"] == "mark": cur = e["name"]
    elif cur and cur.endswith(": Op4: seed") and e["name"] == "minecraft:system_chat":
        b = bytes.fromhex(e["hex"]); _, o = m.parse_varint(b, 0); _, o = m.parse_varint(b, o)
        mt = re.search(rb"copy_to_clipboard.{0,12}?value.{0,4}?(-?[0-9]{1,19})", b[o:], re.S) or re.search(rb"(-?[0-9]{5,19})", b[o:])
        if mt: print(mt.group(1).decode()); sys.exit(0)
sys.exit("no /seed answer in the recording")
