#!/usr/bin/env python3
"""Show the 'diag200'-style run: failures with decoded reasons and times, and the connection count over time from /tmp/scoreboard/diag_poll.log."""
import json, re, sys

tag = sys.argv[1] if len(sys.argv) > 1 else "diag200"
for line in open("/tmp/scoreboard/results.jsonl"):
    r = json.loads(line)
    if r.get("tag") == tag:
        x = r.get("result", {})
        print("run:", r["server"], "n", r["n"], "hold", r["hold"], "error:", r.get("error"))
        for k in ("failed", "failures", "disconnect_reasons", "failure_times_s", "mspt_mean", "mspt_p99", "mspt_max", "ticks", "tps", "over50", "over100", "gateway_late_ticks"):
            print("  ", k, "=", x.get(k))
t = None
rows = []
for l in open("/tmp/scoreboard/diag_poll.log"):
    if l.startswith("== "):
        t = l.split()[1]
    m = re.match(r"conn_play\|(\d+)", l)
    if m:
        rows.append((t, int(m.group(1))))
print("connections in play over time (every 20 s):", " ".join("%s:%d" % (a[3:], b) for a, b in rows[::2]))
