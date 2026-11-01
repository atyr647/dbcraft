#!/usr/bin/env bash
# One socket test: server (BEAM, cores 0-2, +S 3) and Go client (core 3).
#   run_sock.sh NCONN MODE DUR [HOLD_MB] [PERCONN_KB] [FRAMES]    MODE=closed|open|pg
# fd limit in this container is 20000 (hard), so NCONN stays below ~19500.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); OUT=$HERE/out; mkdir -p "$OUT"
N=$1; MODE=$2; DUR=$3; HOLD=${4:-0}; KB=${5:-0}; FR=${6:-5}
PORT=$((25700 + RANDOM % 200)); CM=$MODE; [ "$MODE" = pg ] && CM=open
LOG=$OUT/sock.$N.$MODE.h$HOLD.k$KB.log
echo "== NCONN=$N TICK_PRIO=${TICK_PRIO:-normal} MODE=$MODE DUR=$DUR HOLD_MB=$HOLD(${HOLD_KIND:-bins}) PERCONN_KB=$KB frames/tick=$FR  loadavg=$(cut -d' ' -f1 /proc/loadavg) pressure=$(head -1 /proc/pressure/cpu | cut -d' ' -f2)"
PORT=$PORT NCONN=$N DUR=$DUR CHAOS=${CHAOS:-0} TICK_PRIO=${TICK_PRIO:-normal} GW_MODE=$MODE HOLD_MB=$HOLD HOLD_KIND=${HOLD_KIND:-bins} PERCONN_KB=$KB \
  taskset -c 0-2 elixir --erl "+S 3:3 +Q 65536 +P 2000000" "$HERE/sock_server.exs" > "$LOG" 2>&1 &
SP=$!
for i in $(seq 1 600); do grep -q "SERVER listening" "$LOG" 2>/dev/null && break; sleep 0.2; done
taskset -c 3 "$HERE/client/gwclient" -n "$N" -port "$PORT" -mode "$CM" -frames "$FR" -dur $((DUR + 6)) > "$OUT/client.log" 2>&1
wait $SP 2>/dev/null
grep -E "^(SOCKET|MEMORY|TICK50|MONITOR|PGBATCH|HOLDER|CHAOS)" "$LOG" | sort | uniq -c | sed "s/^ *1 //"; grep CLIENT "$OUT/client.log" | tail -1
