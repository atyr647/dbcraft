#!/usr/bin/env python3
"""Compare two recordings of tests/e2e/container_probe.py (vanilla and dbcraft): per step the packets the click itself caused and the full menu state that followed.

usage: compare_container.py VANILLA.json OURS.json [--quiet]
Exit code 0 when every step is equal.
"""
import json, sys

def norm(r):
    """vanilla re-signals an open chest's lid every 5 ticks, so how many block events a window holds depends on the timing: keep one per run, and only in the steps that
    open or close (a block_event stays in the list of a step whose action is use or close)"""
    for st in r["steps"]:
        keep = st["action"]["op"] in ("use", "close")
        out, seen = [], False
        for p_ in st["packets"]:
            if p_[0] == "block_event":
                if not keep or seen or (st["action"]["op"] == "close" and p_[3] != 0):      # (a close window can hold a lid re-signal that is still "open": only the closing event counts)
                    continue
                seen = True
            out.append(p_)
        if st["action"]["op"] == "drag":            # vanilla adds the dragged-over slots in the order of a HashSet of Slot objects (identity hash codes: different in every run), dbcraft in ascending order:
            out = [["set_slot", x[1], x[2], x[3], "*"] if x[0] == "set_slot" and x[3] == 0 else x for x in out]      # the intermediate results of the crafting grid differ, everything else is the same
        if st["action"]["op"] == "close":           # a barrel's closing block_update comes before the inventory menu's broadcast in vanilla and after it here (dbcraft sends block changes at the end of the tick)
            out = [x for x in out if x[0] != "block_update"] + [x for x in out if x[0] == "block_update"]
        near = lambda x: x[0] != "block_update" or (0 <= x[1][0] <= 4 and -60 <= x[1][1] <= -59 and -2 <= x[1][2] <= 2)    # a block_update away from the container is world noise (vanilla's random updates)
        out = [x for x in out if near(x)]
        if st["action"]["op"] not in ("use", "close"):      # and none belongs to a click on a menu
            out = [x for x in out if x[0] != "block_update"]
        st["packets"] = out
        st["state"] = [x for x in st["state"] if x[0] != "block_event" and (x[0] != "block_update" or st["action"]["op"] in ("use", "close"))]
    return r


a = norm(json.load(open(sys.argv[1])))
b = norm(json.load(open(sys.argv[2])))
quiet = "--quiet" in sys.argv
bad = 0
if a["initial"] != b["initial"]:
    print("INITIAL STATE DIFFERS"); print(" vanilla:", {k: v for k, v in a["initial"]["menu"].items() if v}); print(" ours   :", {k: v for k, v in b["initial"]["menu"].items() if v}); bad += 1
n = min(len(a["steps"]), len(b["steps"]))
for i in range(n):
    sa, sb = a["steps"][i], b["steps"][i]
    if sa["packets"] != sb["packets"] or sa["state"] != sb["state"]:
        bad += 1
        if bad <= 6 or not quiet:
            print(f"step {i} DIFFERS: {json.dumps(sa['action'])}")
            if sa["packets"] != sb["packets"]:
                print("  vanilla packets:", json.dumps(sa["packets"])); print("  ours    packets:", json.dumps(sb["packets"]))
            if sa["state"] != sb["state"]:
                for x, y in zip(sa["state"], sb["state"]):
                    if x != y:
                        if x[0] == "set_content" and y[0] == "set_content":
                            print("  state ids / carried:", x[1:3], x[4], "|", y[1:3], y[4])
                            for k, (p, q) in enumerate(zip(x[3], y[3])):
                                if p != q:
                                    print(f"   slot {k}: vanilla {p} ours {q}")
                        else:
                            print("  state:", x, y)
if len(a["steps"]) != len(b["steps"]):
    print("different number of steps", len(a["steps"]), len(b["steps"])); bad += 1
print(("OK   " if not bad else "FAIL ") + f"{n} steps compared, {bad} differ ({a['scenario']} seed {a['seed']})")
sys.exit(1 if bad else 0)
