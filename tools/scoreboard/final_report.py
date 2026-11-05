#!/usr/bin/env python3
"""The final scoreboard campaign's table: reads the campaign's results.jsonl (tools/scoreboard/campaign.sh, terrain.py) and prints markdown rows, one per metric:
median over the repetitions with [min-max] for vanilla and dbcraft, the ratio dbcraft / vanilla, and the winner.  A difference is a TIE when the two [min-max]
ranges overlap (the rule of docs/SCOREBOARD.md); otherwise the winner is named with the factor between the medians.  Each row also lists the load average at the start of its cells.
usage: final_report.py RESULTS.jsonl [--mobs OUTDIR] [--rows FILE.json]"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C


def get(d, path):
    cur = d
    try:
        for part in path.split("."):
            cur = cur[int(part)] if isinstance(cur, list) else cur[part]
    except (KeyError, IndexError, TypeError, ValueError):
        return None
    return cur


def fmt(v):
    if v is None:
        return "-"
    if abs(v) >= 1000:
        return "{:,.0f}".format(v)
    if abs(v) >= 100:
        return "%.0f" % v
    if abs(v) >= 10:
        return "%.1f" % v
    if abs(v) >= 1:
        return "%.2f" % v
    return "%.3f" % v


def rng(xs):
    return "%s [%s-%s]" % (fmt(C.percentile(xs, 50)), fmt(min(xs)), fmt(max(xs)))


def verdict(v, d, better="low"):
    """winner, factor text.  Ranges that overlap are a tie."""
    if not v or not d:
        return "-", ""
    mv, md = C.percentile(v, 50), C.percentile(d, 50)
    if not (max(d) < min(v) or max(v) < min(d)):
        return "TIE", ("ratio %.2f" % (md / mv)) if mv else ""
    dwins = (md < mv) == (better == "low")
    if mv == 0 or md == 0:
        return ("dbcraft" if dwins else "vanilla"), ""
    f = max(md, mv) / min(md, mv)
    return ("dbcraft" if dwins else "vanilla"), "%.1fx" % f


# (scenario, n, moving, tag) -> label ; metrics: (name, vanilla key, dbcraft key, better)
POP = [("tick mean (ms)", "mspt_mean", "mspt_mean", "low"), ("tick p99 (ms)", "mspt_p99", "mspt_p99", "low"), ("CPU (cores, dbcraft incl. gateway)", "cpu_cores", "cpu_cores", "low"),
       ("memory PSS (MiB)", "mem_mib", "mem_mib", "low"), ("chat p50 (ms)", "rtt_p50", "rtt_p50", "low"), ("chat p99 (ms)", "rtt_p99", "rtt_p99", "low"),
       ("clients dropped", "failed", "failed", "low")]
POP500 = POP + [("clients in play when the window started (of 500)", "ready_clients", "ready_clients", "high"),
                ("load generator CPU over the window (cores; both servers share the 4 cores with it)", "loadgen_cpu_cores", "loadgen_cpu_cores", "low"),
                ("whole machine busy (cores of 4)", "machine_busy_cores", "machine_busy_cores", "low")]
SPECS = [
    (("idle0", 0, 0.0, "idle"), "idle, 0 players", [POP[0], POP[1], POP[2], POP[3]]),
    (("pop", 50, 0.0, "idle"), "idle, 50 players", POP),
    (("pop", 200, 0.0, "idle"), "idle, 200 players", POP),
    (("pop", 50, 1.0, "walk"), "50 players all walking", POP),
    (("pop", 200, 1.0, "walk"), "200 players all walking", POP),
    (("pop", 200, 0.2, "walk"), "200 players, 20% walking", POP),
    (("storm2", 50, 0.0, "storm"), "login storm: 50 joins in 1 s into 20 online",
     [("all joined, all chunks (s)", "time_to_ready_s", "time_to_ready_s", "low"),
      ("worst tick (ms; vanilla: worst 100-tick window p99, dbcraft: worst tick)", "mspt_worst_window_p99", "mspt_max", "low"),
      ("tick p99 over the storm (ms; vanilla: median window p99)", "mspt_p99", "mspt_p99", "low"),
      ("online players' chat during the storm p50 (ms)", "online_during.p50", "online_during.p50", "low"), ("online players' chat during the storm p99 (ms)", "online_during.p99", "online_during.p99", "low"),
      ("online players' chat during the storm max (ms)", "online_during.max", "online_during.max", "low"), ("online players dropped", "online_failed", "online_failed", "low"),
      ("joiners dropped", "failed", "failed", "low")]),
    (("storm2", 200, 0.0, "storm"), "login storm: 200 joins in 1 s into 20 online",
     [("all joined, all chunks (s)", "time_to_ready_s", "time_to_ready_s", "low"),
      ("worst tick (ms; vanilla: worst 100-tick window p99, dbcraft: worst tick)", "mspt_worst_window_p99", "mspt_max", "low"),
      ("tick p99 over the storm (ms; vanilla: median window p99)", "mspt_p99", "mspt_p99", "low"),
      ("online players' chat during the storm p50 (ms)", "online_during.p50", "online_during.p50", "low"), ("online players' chat during the storm p99 (ms)", "online_during.p99", "online_during.p99", "low"),
      ("online players' chat during the storm max (ms)", "online_during.max", "online_during.max", "low"), ("online players dropped", "online_failed", "online_failed", "low"),
      ("joiners dropped", "failed", "failed", "low")]),
    (("chunkload", 50, 0.0, "chunkload"), "one joiner, view distance 10",
     [("unexplored world, all chunks (s)", "unexplored.to_last_chunk_s.0", "unexplored.to_last_chunk_s.0", "low"), ("explored world, all chunks (s)", "explored.to_last_chunk_s.0", "explored.to_last_chunk_s.0", "low")]),
    (("edit", 0, 0.0, "edit"), "edits, nobody in range",
     [("single block edit, statement p50 (ms)", "single_stats.p50_ms", "single_stats.p50_ms", "low"), ("single block edit, tick cost (ms)", "single_tick_stats.mean_ms", "single_tick_stats.mean_ms", "low"),
      ("fill 1,000 blocks, statement p50 (ms)", "fill1k_stats.p50_ms", "fill1k_stats.p50_ms", "low"), ("fill 1,000 blocks, tick cost (ms)", "fill1k_tick_stats.p50_ms", "fill1k_tick_stats.p50_ms", "low"),
      ("fill 100,000 blocks, statement p50 (ms)", "fill100k_stats.p50_ms", "fill100k_stats.p50_ms", "low"), ("fill 100,000 blocks, tick cost (ms)", "fill100k_tick_stats.p50_ms", "fill100k_tick_stats.p50_ms", "low")]),
    (("edit", 1, 0.0, "edit"), "edits, one viewer in range",
     [("single block edit, statement p50 (ms)", "single_stats.p50_ms", "single_stats.p50_ms", "low"), ("single block edit, tick cost (ms)", "single_tick_stats.mean_ms", "single_tick_stats.mean_ms", "low"),
      ("fill 1,000 blocks, statement p50 (ms)", "fill1k_stats.p50_ms", "fill1k_stats.p50_ms", "low"), ("fill 1,000 blocks, tick cost (ms)", "fill1k_tick_stats.p50_ms", "fill1k_tick_stats.p50_ms", "low"),
      ("fill 100,000 blocks, statement p50 (ms)", "fill100k_stats.p50_ms", "fill100k_stats.p50_ms", "low"), ("fill 100,000 blocks, tick cost (ms)", "fill100k_tick_stats.p50_ms", "fill100k_tick_stats.p50_ms", "low")]),
    (("blocks", 50, 0.0, "blocks"), "admin edit path, nobody in range (RCON against psql, many statements)",
     [("single block edit p50 (ms)", "single_edit.p50_ms", "single_edit.p50_ms", "low"), ("single edits per second", "single_edits_per_s", "single_edits_per_s", "high"),
      ("fill 1,000 blocks p50 (ms)", "fill_1k.p50_ms", "fill_1k.p50_ms", "low"), ("fill 100,000 blocks p50 (ms)", "fill_100k.p50_ms", "fill_100k.p50_ms", "low")]),
    (("world10k", 50, 0.0, "world10k"), "10,000-chunk flat world",
     [("generation (s)", "generate_s", "generate_s", "low"), ("size after save (MiB; dbcraft: sum of the world tables)", "world_mib", "world_mib", "low"),
      ("save stall (s; vanilla save-all flush, dbcraft CHECKPOINT)", "save_all_flush_s", "checkpoint_s", "low"), ("kill -9 to accepting logins (s)", "recovery_to_accepting_s", "recovery_to_accepting_s", "low"),
      ("edit saved before kill -9 survives (1 = yes, mean of the reps)", "saved_edit_survived", "saved_edit_survived", "high"),
      ("edit made 1 s before kill -9, never saved, survives (1 = yes, mean of the reps)", "unsaved_edit_survived", "unsaved_edit_survived", "high")]),
    (("terrain", 64, 0.0, "terrain"), "terrain generation, 64 x 64 chunks (NOT like for like)",
     [("CPU per chunk, whole process tree, steady (ms)", "ms_per_chunk_cpu_steady", "ms_per_chunk_cpu_steady", "low"), ("CPU per chunk, all incl. warm-up (ms)", "ms_per_chunk_cpu_all", "ms_per_chunk_cpu_all", "low"),
      ("wall per chunk (ms)", "ms_per_chunk_wall_steady", "ms_per_chunk_wall_steady", "low")]),
    (("pop", 200, 1.0, "soak"), "10-minute soak, 200 walking players",
     [("tick mean (ms; dbcraft: last 5 minutes; vanilla: one answered `tick query` in 10 minutes)", None, "mspt_mean", "low"), ("tick p99 (ms; dbcraft: last 5 minutes)", None, "mspt_p99", "low"),
      ("vanilla RCON `tick query` polls unanswered for 20 s (of about 27 polls)", "rcon_timeouts", None, "low"), ("CPU (cores)", "cpu_cores", "cpu_cores", "low"), ("clients dropped", "failed", "failed", "low"),
      ("chat p50 (ms)", "rtt_p50", "rtt_p50", "low")]),
    (("pop", 500, 1.0, "crowd"), "crowded spawn: 500 players in 30 x 30 chunks, all moving", POP500),
    (("pop", 500, 0.2, "crowd"), "crowded spawn: 500 players in 30 x 30 chunks, 20% moving", POP500),
    (("pop", 500, 1.0, "sparse"), "500 players over 100 x 100 chunks, all moving", POP500),
    (("pop", 500, 0.2, "sparse"), "500 players over 100 x 100 chunks, 20% moving", POP500),
]


def load(path):
    rows = [json.loads(l) for l in open(path)]
    return [r for r in rows if r.get("tag") != "smoke"]


def group(rows, key):
    scen, n, mv, tag = key
    out = {"vanilla": [], "dbcraft": []}
    for r in rows:
        if r["scenario"] != scen or r.get("tag") != tag or r["n"] != n or abs(r["moving"] - mv) > 1e-9:
            continue
        out["vanilla" if r["server"] == "vanilla" else "dbcraft"].append(r)
    return out


def values(runs, key):
    xs = []
    for r in runs:
        res = r.get("result")
        if not res:
            continue
        res = dict(res)
        if res.get("world_bytes"):
            res["world_mib"] = res["world_bytes"] / 1048576.0
        v = get(res, key)
        if isinstance(v, bool):
            v = float(v)
        if v is not None:
            xs.append(float(v))
    return xs


def build(rows):
    out = []
    for key, label, metrics in SPECS:
        g = group(rows, key)
        if not g["vanilla"] and not g["dbcraft"]:
            continue
        loads = [r["load_before"]["load1"] for r in g["vanilla"] + g["dbcraft"]]
        errs = ["%s rep %d: %s" % (r["server"], r["rep"], r["error"]) for r in g["vanilla"] + g["dbcraft"] if r.get("error")]
        for name, vk, dk, better in metrics:
            v, d = (values(g["vanilla"], vk) if vk else []), (values(g["dbcraft"], dk) if dk else [])
            if not v and not d:
                continue
            w, f = verdict(v, d, better)
            out.append({"scenario": label, "metric": name, "vanilla": rng(v) if v else ("no usable samples" if not vk else "not run"), "dbcraft": rng(d) if d else "not run", "ratio": ("%.2f" % (C.percentile(d, 50) / C.percentile(v, 50)))
                        if v and d and C.percentile(v, 50) else "", "winner": w, "by": f, "reps": "%d/%d" % (len(v), len(d)),
                        "load": "%.1f-%.1f" % (min(loads), max(loads)) if loads else "", "errors": errs,
                        "vmed": C.percentile(v, 50) if v else None, "dmed": C.percentile(d, 50) if d else None, "better": better})
    return out


def markdown(rows_out):
    lines = ["| scenario | metric | vanilla median [min-max] | dbcraft median [min-max] | ratio d/v | winner | reps v/d | load avg at cell start |", "|---|---|---|---|---|---|---|---|"]
    for r in rows_out:
        win = r["winner"] + ((" (" + r["by"] + ")") if r["by"] and r["winner"] != "TIE" else (" (" + r["by"] + ")" if r["by"] else ""))
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (r["scenario"], r["metric"], r["vanilla"], r["dbcraft"], r["ratio"], win, r["reps"], r["load"]))
    errs = sorted({e for r in rows_out for e in r["errors"]})
    if errs:
        lines += ["", "Runs that failed:"] + ["- " + e for e in errs]
    return "\n".join(lines)


if __name__ == "__main__":
    path = sys.argv[1]
    rows = load(path)
    ro = build(rows)
    print(markdown(ro))
    if "--rows" in sys.argv:
        json.dump(ro, open(sys.argv[sys.argv.index("--rows") + 1], "w"), indent=1)
