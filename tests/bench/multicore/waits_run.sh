#!/usr/bin/env bash
# usage: waits_run.sh WORKLOAD CLIENTS [SECONDS]    (cluster from PGHOST/PGPORT/PGUSER, database pgb)
# Runs pgbench with the workload while a second session samples pg_stat_activity every 100 ms; prints tps and the sampled wait events (CPU = no wait event = running).
set -euo pipefail
DIR="$(dirname "$0")"
W=${1:-upd_log}; N=${2:-4}; SECS=${3:-7}
OUT=$(mktemp)
timeout $((SECS + 2)) psql -X -q -d postgres -f "$DIR/waits.sql" > "$OUT" 2>&1 &
sleep 0.5
pgbench -n -c "$N" -j "$N" -T "$SECS" -f "$DIR/pgb_$W.sql" pgb 2>&1 | awk '/^tps/ {print "tps=" $3}'
sleep 2
echo "wait events for $W with $N clients (samples):"
sort "$OUT" | uniq -c | sort -rn | head -8
rm -f "$OUT"
