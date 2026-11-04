#!/usr/bin/env python3
"""Writes an action plan for container_probe.py --actions: with an item in the hand a sneaking player does not open a chest (the item is used on the block instead, which
sends the clicked block and the block beside the face again), a standing one does.   usage: container_plan_sneak.py OUT.json"""
import json, sys
use = {"op": "use", "pos": [2, -60, 0]}
plan = {"scenario": "chest", "facing": "north", "seed": 99,
        "stacks": {"36": ["minecraft:stick", 5], "37": ["minecraft:coal", 9]},
        "block": {"0": ["minecraft:iron_ingot", 3], "4": ["minecraft:oak_planks", 20]},
        "steps": [{"action": a} for a in (
            {"op": "held", "slot": 0}, {"op": "input", "flags": 32}, use, {"op": "input", "flags": 0}, use,
            {"op": "click", "slot": 0, "button": 0, "input": 1}, {"op": "close"},
            {"op": "held", "slot": 1}, {"op": "input", "flags": 32}, use, {"op": "input", "flags": 0})]}
json.dump(plan, open(sys.argv[1], "w"))
