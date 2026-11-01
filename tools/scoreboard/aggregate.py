#!/usr/bin/env python3
"""Aggregate $SCORE_OUT/results.jsonl into the scoreboard table (markdown on stdout).

usage: aggregate.py [results.jsonl] [--tags core,storm,...]
Per scenario and metric: median over the repetitions with [min-max], vanilla vs dbcraft, ratio dbcraft/vanilla, winner.  A row is a TIE when the two
[min-max] ranges overlap or the ratio is within 10%.  Lower is better unless the metric is a throughput (edits/s).
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

METRICS = {
    "idle0": [("tick mean (ms)", "mspt_mean", "low"), ("CPU (cores)", "cpu_cores", "low"), ("memory (MiB, PSS)", "mem_mib", "low")],
    "pop": [("tick mean (ms)", "mspt_mean", "low"), ("tick p99 (ms)", "mspt_p99", "low"), ("CPU (cores)", "cpu_cores", "low"), ("memory (MiB, PSS)", "mem_mib", "low"),
            ("chat round trip p50 (ms)", "rtt_p50", "low"), ("chat round trip p99 (ms)", "rtt_p99", "low")],
    "storm": [("all joined + all chunks (s)", "time_to_ready_s", "low"), ("per-client time to all chunks, median (s)", "join_all_chunks_p50_s", "low"),
              ("per-client time to all chunks, max (s)", "join_all_chunks_max_s", "low"), ("server CPU for the storm (s)", "cpu_s_total", "low"),
              ("worst tick during the storm (ms)", ["mspt_max", "mspt_worst_window_avg"], "low")],
    "blocks": [("single setblock latency p50 (ms)", "single_edit.p50_ms", "low"), ("single edits per second (admin path)", "single_edits_per_s", "high"),
               ("fill 1,000 blocks p50 (ms)", "fill_1k.p50_ms", "low"), ("fill 100,000 blocks p50 (ms)", "fill_100k.p50_ms", "low")],
    "chunkload": [("first join, unexplored world, all chunks (s)", "unexplored.to_last_chunk_s.0", "low"), ("join into the explored world, all chunks (s)", "explored.to_last_chunk_s.0", "low")],
    "world10k": [("generate 10,000 chunks (s)", "generate_s", "low"), ("world size after save (MiB)", "world_mib", "low"),
                 ("save stall: save-all flush / checkpoint (s)", ["save_all_flush_s", "checkpoint_s"], "low"), ("kill -9 to accepting logins (s)", "recovery_to_accepting_s", "low")],
}


def get(d, path):
    keys = path if isinstance(path, list) else [path]
    for k in keys:
        cur = d
        try:
            for part in k.split("."):
                cur = cur[int(part)] if isinstance(cur, list) else cur[part]
            if cur is not None:
                return cur
        except (KeyError, IndexError, TypeError, ValueError):
            continue
    return None


def med(xs):
    return C.percentile(xs, 50)


def fmt(v):
    if v is None:
        return "-"
    return ("%.2f" % v) if abs(v) < 100 else ("%.0f" % v)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default=os.path.join(C.OUT, "results.jsonl"))
    ap.add_argument("--tags", default=None)
    ns = ap.parse_args()
    path = ns.path
    tags = ns.tags.split(",") if ns.tags else None
    rows = [json.loads(l) for l in open(path)]
    rows = [r for r in rows if r.get("tag") not in ("smoke",) and (tags is None or r.get("tag") in tags)]
    groups = {}
    for r in rows:
        if "result" not in r:
            continue
        r["result"]["world_mib"] = (r["result"].get("world_bytes") or 0) / 1048576.0 if r["result"].get("world_bytes") else None
        key = (r["scenario"], r["n"], r["moving"], r["vd"], r.get("tag"))
        srv = "vanilla" if r["server"] == "vanilla" else "dbcraft"
        groups.setdefault(key, {}).setdefault(srv, []).append(r)
    print("| scenario | metric | vanilla median [min-max] | dbcraft median [min-max] | ratio d/v | winner | reps v/d | notes |")
    print("|---|---|---|---|---|---|---|---|")
    for key in sorted(groups, key=lambda k: (list(METRICS).index(k[0]) if k[0] in METRICS else 99, k[1], k[2])):
        scen, n, mv, vd, tag = key
        g = groups[key]
        if "vanilla" not in g or "dbcraft" not in g or scen not in METRICS:
            continue
        label = {"idle0": "idle, 0 players", "pop": "%d players, %d%% moving" % (n, round(mv * 100)), "storm": "login storm, %d joins in 1 s" % n,
                 "blocks": "block edits", "chunkload": "one joiner, view distance %d" % vd, "world10k": "10,000-chunk flat world"}[scen]
        mode = g["dbcraft"][0]["server"].split(":")[-1]
        notq = sum(1 for r in g["vanilla"] + g["dbcraft"] if not r.get("quiet_reached", True))
        loads = [r["load_before"]["load1"] for r in g["vanilla"] + g["dbcraft"]]
        busy = [r.get("machine_busy_frac") for r in g["vanilla"] + g["dbcraft"] if r.get("machine_busy_frac") is not None]
        notes = "dbcraft %s tick; %d/%d runs on a busy machine (load1 median %.1f)" % (mode, notq, len(g["vanilla"]) + len(g["dbcraft"]), med(loads))
        for name, mkey, better in METRICS[scen]:
            v = [get(r["result"], mkey) for r in g["vanilla"]]
            d = [get(r["result"], mkey) for r in g["dbcraft"]]
            v = [x for x in v if x is not None]
            d = [x for x in d if x is not None]
            if not v or not d:
                continue
            mv_, md_ = med(v), med(d)
            ratio = md_ / mv_ if mv_ else float("inf")
            overlap = not (max(d) < min(v) or max(v) < min(d))
            if overlap or 0.9 <= ratio <= 1.1:
                win = "tie (within noise)"
            else:
                win = "dbcraft" if ((md_ < mv_) == (better == "low")) else "vanilla"
            print("| %s | %s | %s [%s-%s] | %s [%s-%s] | %.2f | %s | %d/%d | %s |" % (
                label, name, fmt(mv_), fmt(min(v)), fmt(max(v)), fmt(md_), fmt(min(d)), fmt(max(d)), ratio, win, len(v), len(d), notes))
    # failures and flags
    bad = [r for r in rows if r.get("error")]
    if bad:
        print("\nRuns that failed:")
        for r in bad:
            print("- %s %s n=%s rep=%s: %s" % (r["scenario"], r["server"], r["n"], r["rep"], r["error"]))


if __name__ == "__main__":
    main()
