#!/usr/bin/env bash
# Keep a real client connected to the dbcraft server for N minutes while it walks back and forth across chunk borders; sample once a minute.
# usage: [LAP_SECONDS=3] tools/realclient/soak.sh [MINUTES=10] [NAME=Probe]   (LAP_SECONDS=12 walks about 50 blocks each way: several chunk borders)       output: /tmp/mc-client/soak.log and screenshots /tmp/mc-client/shots/soak-NN.png
# Each sample: the player row, the gateway tick statistics, the error log, errors in the client log, a screenshot.
set -uo pipefail
cd "$(dirname "$0")/../.."
MIN=${1:-10}; NAME=${2:-Probe}; LOG=/tmp/mc-client/soak.log; D=tools/realclient
: > "$LOG"
start=$(date +%s)
sample() {
  echo "--- sample $1 at +$(( $(date +%s) - start )) s" >> "$LOG"
  $D/dbcraft_server.sh player >> "$LOG" 2>&1
  $D/dbcraft_server.sh status >> "$LOG" 2>&1
  echo "error_log rows: $($D/dbcraft_server.sh psql -tA -c 'select count(*) from mc.error_log' 2>&1)" >> "$LOG"
  echo "client log errors: $(grep -c -i -E 'Exception|Disconnect|Failed to (decode|read|process)|Network Protocol Error|Invalid' /tmp/mc-client/game-$NAME/logs/latest.log 2>/dev/null)" >> "$LOG"
  $D/run_client.sh shot "$NAME" "/tmp/mc-client/shots/soak-$(printf %02d "$1").png" >> "$LOG" 2>&1
}
$D/drive.sh focus
sample 0
n=0; next=60
while [ $(( $(date +%s) - start )) -lt $(( MIN * 60 )) ]; do
  # one lap: south ~13 blocks, turn around, north ~13 blocks, turn around (crosses the chunk border at z = 16 each way)
  $D/drive.sh hold w "${LAP_SECONDS:-3}"; $D/drive.sh look 1200 0; sleep 0.5
  $D/drive.sh hold w "${LAP_SECONDS:-3}"; $D/drive.sh look 1200 0; sleep 0.5
  if [ $(( $(date +%s) - start )) -ge "$next" ]; then n=$((n + 1)); next=$((next + 60)); sample "$n"; fi
done
sample final
echo "soak finished after $(( $(date +%s) - start )) s" >> "$LOG"
