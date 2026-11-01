#!/usr/bin/env bash
# Keeps a REAL vanilla client connected through the Rust gateway for N minutes while it walks laps across chunk borders; samples once a minute.
# usage: [LAP_SECONDS=12] tests/gateway/soak_rust.sh [MINUTES=5] [NAME=RustProbe]
# Needs: the gateway running (tests/gateway/run_e2e_rust.sh shows how to start it), the client joined (tools/realclient/run_client.sh start NAME 127.0.0.1:25651),
#        DBCRAFT_PGPORT (default 54655).  Output: /tmp/mc-client/soak-rust.log and screenshots /tmp/mc-client/shots/soak-rust-NN.png
set -uo pipefail
cd "$(dirname "$0")/../.."
MIN=${1:-5}; NAME=${2:-RustProbe}; LOG=/tmp/mc-client/soak-rust.log; D=tools/realclient
PSQL="psql -X -At -h /tmp -p ${DBCRAFT_PGPORT:-54655} -U postgres dbcraft"
: > "$LOG"
start=$(date +%s)
sample() {
  {
    echo "--- sample $1 at +$(( $(date +%s) - start )) s"
    echo "player: $($PSQL -c "select name || ' x=' || round(x::numeric,1) || ' z=' || round(z::numeric,1) || ' chunk=' || chunk_x || ',' || chunk_z from mc.player where conn_id is not null")"
    echo "gateway: $($PSQL -c "select 'ticks/s=' || ticks || ' late=' || late_ticks || ' tick_ms_avg=' || round(tick_ms_avg::numeric,2) || ' max=' || round(tick_ms_max::numeric,2) || ' errors=' || errors || ' conns=' || connections from net.gateway_stats order by ts desc limit 1")"
    echo "mc.error_log rows: $($PSQL -c 'select count(*) from mc.error_log')"
    echo "client log: $(grep -c -E 'Network Protocol Error|Failed to (decode|read|process)|Disconnected|lost connection' /tmp/mc-client/game-$NAME/logs/latest.log 2>/dev/null) protocol/disconnect lines"
  } >> "$LOG" 2>&1
  $D/run_client.sh shot "$NAME" "/tmp/mc-client/shots/soak-rust-$(printf %02d "$1").png" >> /dev/null 2>&1
}
$D/drive.sh focus
$D/drive.sh look 0 -300      # look level again (an earlier test may have looked down)
sample 0
n=0; next=60
while [ $(( $(date +%s) - start )) -lt $(( MIN * 60 )) ]; do
  $D/drive.sh hold w "${LAP_SECONDS:-12}"; $D/drive.sh look 1200 0; sleep 0.5
  if [ $(( $(date +%s) - start )) -ge "$next" ]; then n=$((n + 1)); next=$((next + 60)); sample "$n"; fi
done
sample final
echo "soak finished after $(( $(date +%s) - start )) s" >> "$LOG"
cat "$LOG"
