#!/usr/bin/env python3
"""Run RCON commands on a throwaway vanilla server (tests/e2e/vanilla_start.sh).  usage: vanilla_rcon.py PORT cmd [cmd ...]"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
import common as C
r = C.Rcon(port=int(sys.argv[1]), pw="dbcraft-e2e")
for c in sys.argv[2:]:
    print(c, "->", r.cmd(c))
