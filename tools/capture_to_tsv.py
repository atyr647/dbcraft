#!/usr/bin/env python3
"""Print a vanilla capture (tools/capture_vanilla.py output) as tab-separated rows for `\\copy ... from program`.

usage: tools/capture_to_tsv.py [--path] NAME      NAME = play_nocomp | status | badname ...  -> tests/fixtures/captured/NAME.jsonl
       (directory: $DBCRAFT_CAPTURES, else $DBCRAFT_HOME/captures, else tests/fixtures/captured)
Columns: idx, dir, state, packet_id, name, wire_len, hex      (hex = the complete wire frame including its length prefix)
Prints nothing (exit 0) when the capture does not exist, so a test can skip with a clear message.  Captures are Mojang data and are never committed.
"""
import json, os, sys

want_path = sys.argv[1] == "--path"
name = sys.argv[2] if want_path else sys.argv[1]
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(here, "tools"))
import _capture
path = _capture.find_capture(name)
if want_path:
    print(path or "")
elif path:
    for i, line in enumerate(open(path)):
        r = json.loads(line)
        print("\t".join(map(str, [i, r["dir"], r["state"], r["id"], r["name"], r["len"], r["hex"]])))
