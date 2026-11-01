#!/usr/bin/env bash
# usage: tests/bench/tick/parallel/waits.sh SCRIPT CLIENTS [SECONDS]      e.g.  waits.sh sep_pw 4 6
# Runs pgbench with SCRIPT (sep_pw|sep_pu|shared_pw|shared_pu) and CLIENTS clients and, meanwhile, samples pg_stat_activity of the active backends about 100 times
# a second.  Prints how the samples split over wait events (empty wait = running on a CPU) plus the WAL written per second.
set -euo pipefail
cd "$(dirname "$0")"
SC=$1; C=$2; SECS=${3:-6}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres
PGB=/usr/lib/postgresql/16/bin/pgbench
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
LSN0=$(psql -X -q -At -d pgb -c "select pg_current_wal_lsn()")
$PGB -n -c "$C" -j "$C" -T "$SECS" -f "$SC.sql" pgb > "$OUT.pgb" 2>&1 &
sleep 1
for i in $(seq 1 $((SECS * 100 - 150))); do
  psql -X -q -At -d pgb -c "select coalesce(wait_event_type || ':' || wait_event, 'CPU') from pg_stat_activity where datname = 'pgb' and state = 'active' and pid <> pg_backend_pid() and query like 'select par.%'" >> "$OUT"
  sleep 0.01
done
wait
LSN1=$(psql -X -q -At -d pgb -c "select pg_current_wal_lsn()")
echo "$SC with $C clients: $(awk '/^tps =/ {print $3}' "$OUT.pgb") statements/s;  WAL written: $(psql -X -q -At -d pgb -c "select pg_size_pretty(pg_wal_lsn_diff('$LSN1', '$LSN0') / $SECS) || '/s'")"
sort "$OUT" | uniq -c | sort -rn | head -8 | awk '{printf "   %5s  %s\n", $1, $2}'
rm -f "$OUT.pgb"
