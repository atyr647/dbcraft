#!/usr/bin/env bash
# Does a long-running procedure that COMMITs every tick (the shape of tune.run and of the gateway procedure net.run) hold back vacuum?
# Runs tune.run for SECONDS in the background on a throwaway copy of the golden database and, every 5 s, prints the age of that backend's xmin, the number of dead tuples
# in the queue table mc.play_out and how many times autovacuum has processed it.   If the xmin age keeps growing and the dead tuples are never removed, the CALL pins the horizon.
# usage: tests/bench/tuning/xmin_probe.sh [SECONDS=60] [PLAYERS=200] [CONFS=ref]      env: GOLD, XP_DATA (default /tmp/dbcraft-pg-tune-xp), XP_PORT (default 54479)
set -euo pipefail
cd "$(dirname "$0")/../../.."
SECS=${1:-60}; N=${2:-200}; CONFS=${3:-ref}
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${XP_DATA:-/tmp/dbcraft-pg-tune-xp}; PORT=${XP_PORT:-54479}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
{ echo "include '$PWD/tests/bench/tuning/conf/base.conf'"; IFS=, read -ra L <<< "$CONFS"; for c in "${L[@]}"; do echo "include '$PWD/tests/bench/tuning/conf/$c.conf'"; done; echo "autovacuum_naptime = 5s"; } >> "$DATA/postgresql.conf"
: > "$DATA/log"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/integration/bench.sql -f tests/bench/tuning/steady.sql >/dev/null 2>&1
$P -c "select ibench.setup($N, 100)" -c "select mc.refresh_visibility()" -c "analyze" -c "checkpoint" >/dev/null
( $P -c "call tune.run($((SECS * 20)), 20, 0.25, 0)" >/dev/null 2>&1 & )
sleep 2
echo "t(s) | backend_xmin age | dead tuples mc.play_out | autovacuum runs on it | size"
for i in $(seq 1 $((SECS / 5))); do
  $P -F ' | ' -c "select $((i * 5)) || 's', (select coalesce(age(backend_xmin)::text, 'none (no snapshot)') from pg_stat_activity where query like 'call tune.run%' and pid <> pg_backend_pid() limit 1),
                  (select n_dead_tup from pg_stat_user_tables where relid = 'mc.play_out'::regclass), (select autovacuum_count from pg_stat_user_tables where relid = 'mc.play_out'::regclass),
                  pg_size_pretty(pg_table_size('mc.play_out'))"
  sleep 5
done
echo "autovacuum log lines for play_out:"; grep -A6 'automatic vacuum of table "dbcraft.mc.play_out"' "$DATA/log" | grep -E "automatic vacuum|tuples:|removable cutoff" | head -12
