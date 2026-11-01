#!/usr/bin/env python3
"""Analyse one tuning trial (output of run.sh): latency statistics, counter differences, and which server events overlap the slow ticks.

usage: analyze.py RESULT_DIR --name NAME [--confs C] [--players N] [--frac F] [--seconds S] [--wall S] [--load a,b] [--slow MS]
Reads lat.csv, pg.log, snap_before.json, snap_after.json; writes summary.json and prints one line.  Standard library only.
"""
import argparse, csv, datetime, json, os, re, statistics, sys

ap = argparse.ArgumentParser()
ap.add_argument("dir"); ap.add_argument("--name", default="?"); ap.add_argument("--confs", default="")
ap.add_argument("--players", type=int, default=0); ap.add_argument("--frac", type=float, default=0); ap.add_argument("--seconds", type=int, default=0)
ap.add_argument("--wall", type=int, default=0); ap.add_argument("--load", default="")
ap.add_argument("--slow", type=float, default=0, help="ms; ticks slower than this are attributed (default: max(2 x p50, 60))")
ap.add_argument("--verbose", action="store_true")
a = ap.parse_args()

def pct(xs, p):
    xs = sorted(xs)
    if not xs: return float("nan")
    k = (len(xs) - 1) * p / 100.0; f = int(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)

rows = list(csv.DictReader(open(os.path.join(a.dir, "lat.csv"))))
num = lambda r, k: float(r[k]) if r.get(k) not in (None, "") else 0.0
lat = [num(r, "lat_ms") for r in rows]
tick = [num(r, "tick_ms") for r in rows]
late = [num(r, "late_ms") for r in rows]
n = len(rows)
S = {"name": a.name, "confs": a.confs, "players": a.players, "frac": a.frac, "seconds": a.seconds, "ticks": n, "load": a.load,
     "lat_avg": statistics.fmean(lat), "lat_p50": pct(lat, 50), "lat_p95": pct(lat, 95), "lat_p99": pct(lat, 99), "lat_p999": pct(lat, 99.9), "lat_max": max(lat),
     "over50": sum(1 for x in lat if x > 50), "over100": sum(1 for x in lat if x > 100), "over200": sum(1 for x in lat if x > 200),
     "late_ticks": sum(1 for x in late if x > 0), "late_avg_when_late": statistics.fmean([x for x in late if x > 0]) if any(x > 0 for x in late) else 0.0,
     "commit_avg": statistics.fmean(num(r, "commit_ms") for r in rows), "commit_p99": pct([num(r, "commit_ms") for r in rows], 99), "commit_max": max(num(r, "commit_ms") for r in rows),
     "drain_avg": statistics.fmean(num(r, "drain_ms") for r in rows), "gen_avg": statistics.fmean(num(r, "gen_ms") for r in rows),
     "phase_avg": {k: statistics.fmean(num(r, k) for r in rows) for k in ("ms_process", "ms_game", "ms_blocks", "ms_chunks", "ms_drain")}}

# ---- counters
try:
    b = json.load(open(os.path.join(a.dir, "snap_before.json"))); e = json.load(open(os.path.join(a.dir, "snap_after.json")))
    d = lambda sec, k: (e[sec].get(k) or 0) - (b[sec].get(k) or 0)
    S["checkpoints_timed"] = d("bgwriter", "checkpoints_timed"); S["checkpoints_req"] = d("bgwriter", "checkpoints_req")
    S["buffers_checkpoint"] = d("bgwriter", "buffers_checkpoint"); S["buffers_clean"] = d("bgwriter", "buffers_clean"); S["buffers_backend"] = d("bgwriter", "buffers_backend")
    S["maxwritten_clean"] = d("bgwriter", "maxwritten_clean")
    S["wal_bytes"] = d("wal", "wal_bytes"); S["wal_records"] = d("wal", "wal_records"); S["wal_fpi"] = d("wal", "wal_fpi")
    S["wal_buffers_full"] = d("wal", "wal_buffers_full"); S["wal_write"] = d("wal", "wal_write"); S["wal_sync"] = d("wal", "wal_sync")
    S["wal_kb_per_tick"] = S["wal_bytes"] / max(n, 1) / 1024.0
    S["fpi_share"] = S["wal_fpi"] / max(S["wal_records"], 1)
    S["xact_commit"] = d("db", "xact_commit"); S["blks_read"] = d("db", "blks_read"); S["blks_hit"] = d("db", "blks_hit")
    S["temp_files"] = d("db", "temp_files")
    tabs = {}
    for t, v in e["tables"].items():
        v0 = b["tables"].get(t, {})
        tabs[t] = {k: (v.get(k) or 0) - (v0.get(k) or 0) for k in ("ins", "upd", "del", "hot", "vac", "autovac", "autoan", "seq_scan", "idx_scan")}
        tabs[t].update({"dead": v["dead"], "live": v["live"], "size": v["size"], "idx_size": v["idx_size"], "size_growth": v["size"] - v0.get("size", v["size"]),
                        "hot_pct": (100.0 * tabs[t]["hot"] / tabs[t]["upd"]) if tabs[t]["upd"] else None})
    S["tables"] = tabs
    S["autovacuum_runs"] = sum(v["autovac"] for v in tabs.values()); S["autoanalyze_runs"] = sum(v["autoan"] for v in tabs.values())
    unused = []
    for i, v in e["indexes"].items():
        s0 = b["indexes"].get(i, {}).get("scans", 0)
        if (v["scans"] or 0) - (s0 or 0) == 0: unused.append((i, v["size"], v["table"]))
    S["indexes_unused_in_run"] = sorted(unused, key=lambda x: -x[1])[:25]
except Exception as ex:
    S["snapshot_error"] = str(ex)

# ---- log events with timestamps
def parse_ts(s):
    m = re.match(r"(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\.(\d{3})", s)
    if not m: return None
    return datetime.datetime.strptime(m.group(1) + " " + m.group(2), "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp() + int(m.group(3)) / 1000.0
events = []     # (kind, start, end, text)
ck_start = None
if os.path.exists(os.path.join(a.dir, "pg.log")):
    for line in open(os.path.join(a.dir, "pg.log"), errors="replace"):
        ts = parse_ts(line)
        if ts is None: continue
        if "checkpoint starting" in line: ck_start = ts; ck_why = line.split("checkpoint starting:")[-1].strip()
        elif "checkpoint complete" in line and ck_start is not None:
            events.append(("checkpoint", ck_start, ts, ck_why + " | " + line.split("checkpoint complete:")[-1].strip()[:160])); ck_start = None
        elif "automatic vacuum of table" in line or "automatic analyze of table" in line:
            m = re.search(r"elapsed: ([\d.]+) s", line); el = float(m.group(1)) if m else 0.0
            events.append(("autovacuum" if "vacuum" in line else "autoanalyze", ts - el, ts, line.split("]")[1].strip()[:140] if "]" in line else line.strip()[:140]))
        elif "still waiting for" in line or "acquired" in line and "lock" in line:
            events.append(("lockwait", ts - 0.1, ts, line.strip()[-160:]))
        elif "ERROR" in line or "FATAL" in line or "PANIC" in line:
            events.append(("error", ts, ts, line.strip()[-160:]))
S["events"] = {k: sum(1 for ev in events if ev[0] == k) for k in ("checkpoint", "autovacuum", "autoanalyze", "lockwait", "error")}

# ---- attribution of slow ticks
slow_thr = a.slow or max(2 * S["lat_p50"], 60.0)
S["slow_threshold_ms"] = slow_thr
attr = {"checkpoint": 0, "autovacuum": 0, "autoanalyze": 0, "lockwait": 0, "none": 0}
slow = []
for r in rows:
    L = num(r, "lat_ms")
    if L <= slow_thr: continue
    t0 = num(r, "t_start"); t1 = t0 + (L + num(r, "commit_ms")) / 1000.0
    hit = [ev for ev in events if ev[1] <= t1 and ev[2] >= t0 and ev[0] in attr]
    kinds = sorted({ev[0] for ev in hit}) or ["none"]
    for k in kinds: attr[k] += 1
    slow.append((L, int(num(r, "seq")), kinds, {k: round(num(r, k), 1) for k in ("tick_ms", "commit_ms", "drain_ms", "ms_process", "ms_game", "ms_blocks", "ms_chunks")}, int(num(r, "frames_in")), int(num(r, "frames_out"))))
S["slow_ticks"] = len(slow); S["slow_attribution"] = attr
S["slowest"] = [{"lat_ms": round(x[0], 1), "seq": x[1], "overlap": x[2], "parts": x[3], "frames_in": x[4], "frames_out": x[5]} for x in sorted(slow, reverse=True)[:12]]
S["events_list"] = [(k, round(s - (num(rows[0], "t_start") if rows else 0), 2), round(e - s, 3), t) for (k, s, e, t) in events if k in ("checkpoint", "autovacuum", "autoanalyze", "lockwait")][:60]
json.dump(S, open(os.path.join(a.dir, "summary.json"), "w"), indent=1, default=str)

print(f"{a.name:28s} N={a.players} mv={a.frac:g} {a.seconds}s load={a.load} | lat ms avg {S['lat_avg']:.1f} p50 {S['lat_p50']:.1f} p99 {S['lat_p99']:.1f} p99.9 {S['lat_p999']:.1f} max {S['lat_max']:.1f}"
      f" | >50: {S['over50']} >100: {S['over100']} >200: {S['over200']} late: {S['late_ticks']}/{n} | commit avg {S['commit_avg']:.2f} max {S['commit_max']:.1f}"
      f" | WAL {S.get('wal_kb_per_tick', 0):.0f} KB/tick fpi {100 * S.get('fpi_share', 0):.0f}% | ckpt {S.get('checkpoints_timed', '?')}+{S.get('checkpoints_req', '?')} autovac {S.get('autovacuum_runs', '?')}"
      f" | slow(>{slow_thr:.0f}ms) {S['slow_ticks']}: {attr}")
if a.verbose:
    print(json.dumps({k: S[k] for k in ("slowest", "events_list")}, indent=1, default=str))
