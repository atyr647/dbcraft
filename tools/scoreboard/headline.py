#!/usr/bin/env python3
"""The headline table of docs/SCOREBOARD.md: a selection of the rows of the generated table plus the mobs rows.
usage: headline.py RESULTS.jsonl MOBS_DIR > headline.md"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import final_report as F

PICK = [  # (scenario label, metric prefix, shown name)
    ("idle, 0 players", "tick mean", "tick mean (ms)"), ("idle, 0 players", "CPU", "CPU (cores)"), ("idle, 0 players", "memory", "memory PSS (MiB)"),
    ("idle, 50 players", "tick mean", "tick mean (ms)"), ("idle, 50 players", "tick p99", "tick p99 (ms)"), ("idle, 50 players", "CPU", "CPU (cores)"), ("idle, 50 players", "chat p50", "chat p50 (ms)"),
    ("idle, 50 players", "chat p99", "chat p99 (ms)"), ("idle, 50 players", "memory", "memory PSS (MiB)"),
    ("idle, 200 players", "tick mean", "tick mean (ms)"), ("idle, 200 players", "tick p99", "tick p99 (ms)"), ("idle, 200 players", "CPU", "CPU (cores)"), ("idle, 200 players", "chat p50", "chat p50 (ms)"),
    ("idle, 200 players", "chat p99", "chat p99 (ms)"), ("idle, 200 players", "memory", "memory PSS (MiB)"),
    ("50 players all walking", "tick mean", "tick mean (ms)"), ("50 players all walking", "tick p99", "tick p99 (ms)"), ("50 players all walking", "CPU", "CPU (cores)"),
    ("50 players all walking", "chat p50", "chat p50 (ms)"), ("50 players all walking", "chat p99", "chat p99 (ms)"),
    ("200 players all walking", "tick mean", "tick mean (ms)"), ("200 players all walking", "tick p99", "tick p99 (ms)"), ("200 players all walking", "CPU", "CPU (cores)"),
    ("200 players all walking", "chat p50", "chat p50 (ms; 10,000 = the probe's cap, no reply)"), ("200 players all walking", "chat p99", "chat p99 (ms)"),
    ("200 players, 20% walking", "tick mean", "tick mean (ms)"), ("200 players, 20% walking", "tick p99", "tick p99 (ms)"), ("200 players, 20% walking", "CPU", "CPU (cores)"),
    ("200 players, 20% walking", "chat p50", "chat p50 (ms)"), ("200 players, 20% walking", "chat p99", "chat p99 (ms)"),
    ("login storm: 50", "all joined", "all joined, all chunks (s)"), ("login storm: 50", "worst tick", "worst tick (ms)"), ("login storm: 50", "tick p99", "tick p99 (ms)"),
    ("login storm: 50", "online players' chat during the storm p50", "online players' chat p50 (ms)"), ("login storm: 50", "online players' chat during the storm p99", "online players' chat p99 (ms)"),
    ("login storm: 200", "all joined", "all joined, all chunks (s)"), ("login storm: 200", "worst tick", "worst tick (ms)"), ("login storm: 200", "tick p99", "tick p99 (ms)"),
    ("login storm: 200", "online players' chat during the storm p50", "online players' chat p50 (ms)"), ("login storm: 200", "online players' chat during the storm p99", "online players' chat p99 (ms)"),
    ("one joiner", "unexplored", "unexplored world, all chunks (s)"), ("one joiner", "explored", "explored world, all chunks (s)"),
    ("edits, nobody in range", "single block edit, statement", "single block edit, statement (ms)"), ("edits, nobody in range", "fill 1,000 blocks, statement", "fill 1,000, statement (ms)"),
    ("edits, nobody in range", "fill 1,000 blocks, tick", "fill 1,000, tick cost (ms)"), ("edits, nobody in range", "fill 100,000 blocks, statement", "fill 100,000, statement (ms)"),
    ("edits, nobody in range", "fill 100,000 blocks, tick", "fill 100,000, tick cost (ms)"),
    ("edits, one viewer", "single block edit, statement", "single block edit, statement (ms)"), ("edits, one viewer", "single block edit, tick", "single block edit, tick cost (ms)"),
    ("edits, one viewer", "fill 1,000 blocks, statement", "fill 1,000, statement (ms)"), ("edits, one viewer", "fill 1,000 blocks, tick", "fill 1,000, tick cost (ms)"),
    ("edits, one viewer", "fill 100,000 blocks, statement", "fill 100,000, statement (ms)"), ("edits, one viewer", "fill 100,000 blocks, tick", "fill 100,000, tick cost (ms)"),
    ("admin edit path", "single edits per second", "single edits per second"),
    ("10,000-chunk", "generation", "generation (s)"), ("10,000-chunk", "size after save", "size after save (MiB)"), ("10,000-chunk", "save stall", "save stall (s)"),
    ("10,000-chunk", "kill -9 to accepting", "kill -9 to accepting logins (s)"), ("10,000-chunk", "edit made 1 s", "edit 1 s old, never saved, survives kill -9 (1 = yes)"),
    ("terrain generation", "CPU per chunk, whole process tree, steady", "CPU per chunk (ms), not like for like"),
    ("10-minute soak", "CPU", "CPU (cores)"), ("10-minute soak", "clients dropped", "clients dropped"), ("10-minute soak", "chat p50", "chat p50 (ms)"), ("10-minute soak", "tick mean", "tick mean (ms)"),
    ("10-minute soak", "tick p99", "tick p99 (ms)"),
    ("crowded spawn", "tick mean", "tick mean (ms)"), ("crowded spawn", "tick p99", "tick p99 (ms)"), ("crowded spawn", "clients dropped", "clients dropped (of 500)"),
    ("crowded spawn", "clients in play", "clients in play when measured (of 500)"), ("crowded spawn", "chat p50", "chat p50 (ms)"), ("crowded spawn", "CPU", "CPU (cores)"),
    ("500 players over 100 x 100 chunks, all moving", "tick mean", "tick mean (ms)"), ("500 players over 100 x 100 chunks, all moving", "tick p99", "tick p99 (ms)"),
    ("500 players over 100 x 100 chunks, all moving", "clients dropped", "clients dropped (of 500)"), ("500 players over 100 x 100 chunks, all moving", "chat p50", "chat p50 (ms)"),
    ("500 players over 100 x 100 chunks, 20%", "tick mean", "tick mean (ms)"), ("500 players over 100 x 100 chunks, 20%", "tick p99", "tick p99 (ms)"),
    ("500 players over 100 x 100 chunks, 20%", "clients dropped", "clients dropped (of 500)"), ("500 players over 100 x 100 chunks, 20%", "chat p50", "chat p50 (ms)"),
]


def main():
    rows = F.build(F.load(sys.argv[1]))
    out = ["| Scenario | Metric | vanilla | dbcraft | ratio d/v | winner |", "|---|---|---|---|---|---|"]
    for lab, met, shown in PICK:
        hit = [r for r in rows if r["scenario"].startswith(lab) and r["metric"].startswith(met)]
        if not hit:
            print("MISSING", lab, met, file=sys.stderr)
            continue
        r = hit[0]
        win = r["winner"] + ((" (" + r["by"] + ")") if r["by"] and r["winner"] != "TIE" else "")
        out.append("| %s | %s | %s | %s | %s | %s |" % (r["scenario"].replace(" (RCON against psql, many statements)", ""), shown, r["vanilla"], r["dbcraft"], r["ratio"], win))
    mobs = subprocess.run([sys.executable, os.path.join(HERE, "mobs_report.py"), sys.argv[2]], capture_output=True, text=True, check=True).stdout.splitlines()[2:]
    for l in mobs:
        c = [x.strip() for x in l.strip("|").split("|")]
        if "dbcraft only" in c[0]:
            continue
        out.append("| mobs: %s | entity tick CPU per tick (ms; vanilla: Server thread) | %s | %s | %s | %s |" % (c[0], c[1], c[3], c[5], c[6]))
    print("\n".join(out))


main()
