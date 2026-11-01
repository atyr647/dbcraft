#!/usr/bin/env bash
# How much WAL does ONE `ANALYZE` of each table write?  (pg_statistic is rewritten column by column; autoanalyze repeats it every autovacuum_naptime for every table that changed.)
# Brings a throwaway copy of the golden database to a steady state (200 bots, 200 ticks) and measures the WAL of `analyze <table>` for the tables autovacuum keeps analysing.
# usage: tests/bench/tuning/analyze_wal.sh      env: GOLD, AW_DATA (default /tmp/dbcraft-pg-tune-aw), AW_PORT (default 54483)
set -euo pipefail
cd "$(dirname "$0")/../../.."
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${AW_DATA:-/tmp/dbcraft-pg-tune-aw}; PORT=${AW_PORT:-54483}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
{ echo "include '$PWD/tests/bench/tuning/conf/base.conf'"; echo "include '$PWD/tests/bench/tuning/conf/ref.conf'"; echo "autovacuum = off"; } >> "$DATA/postgresql.conf"
: > "$DATA/log"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/integration/bench.sql -f tests/bench/tuning/steady.sql >/dev/null 2>&1
$P -c "select ibench.setup(200, 100)" -c "select mc.refresh_visibility()" -c "analyze" -c "checkpoint" >/dev/null
python3 tests/bench/tuning/steady_top.py --ticks 200 --frac 0.25 --csv /tmp/dbcraft-aw-lat.csv >/dev/null
$P -c "\\copy tune.lat from '/tmp/dbcraft-aw-lat.csv' csv" >/dev/null; rm -f /tmp/dbcraft-aw-lat.csv
$P -c "checkpoint" >/dev/null
printf '%-34s %12s %14s %10s\n' "ANALYZE of" "WAL bytes" "pg_statistic" "columns"
for t in mc.player net.conn net.outbox net.inbox mc.play_in mc.play_out net.batch mc.tick_log mc.server_tick_log mc.game_state mc.visible ibench.step tune.lat pg_catalog.pg_class pg_catalog.pg_attribute pg_catalog.pg_statistic; do
  L0=$($P -c "select pg_current_wal_lsn()")
  $P -c "analyze $t" >/dev/null
  L1=$($P -c "select pg_current_wal_lsn()")
  B=$($P -c "select pg_wal_lsn_diff('$L1', '$L0')")
  C=$($P -c "select count(*) from pg_attribute where attrelid = '$t'::regclass and attnum > 0 and not attisdropped and attstattarget <> 0")
  printf '%-34s %12s %14s %10s\n' "$t" "$B" "-" "$C"
done
