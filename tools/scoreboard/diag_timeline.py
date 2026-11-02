#!/usr/bin/env python3
"""Print the timeline recorded by diag_poll.sh (every 20 s): connections, pending keep-alives, bloat of mc.player, queue sizes, recent tick times."""
cur = {}
out = []
for line in open("/tmp/scoreboard/diag_poll.log"):
    if line.startswith("== "):
        if cur:
            out.append(cur)
        cur = {"t": line.split()[1][3:]}
    for k in ("conn_play", "keepalive_pending", "player_bloat", "queues", "last_ticks_ms", "gateway"):
        if line.startswith(k + "|"):
            cur[k] = line.strip().split("|", 1)[1]
out.append(cur)
for c in out:
    print(c.get("t"), "play", c.get("conn_play"), "| ka_pending(n,max age in ticks)", c.get("keepalive_pending"), "| player live/dead/hot/upd", c.get("player_bloat"),
          "| queues in/work/out/playout", c.get("queues"), "| last100 ticks avg/max", c.get("last_ticks_ms"), "| gw ticks/last/max/late/conns", c.get("gateway"))
