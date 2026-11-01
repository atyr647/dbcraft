#!/usr/bin/env bash
# Where does the tick do file I/O?  Runs the gateway-style loop for a while on a throwaway copy of the golden database and prints pg_stat_io (PostgreSQL 16):
# writes, extends and fsyncs by object (relation / temp relation / WAL) and context, for the backend that runs the ticks.
# usage: tests/bench/tuning/io_probe.sh [TICKS=600] [PLAYERS=200] [CONFS=ref,av_nap10]     env: GOLD, IO_DATA (default /tmp/dbcraft-pg-tune-io), IO_PORT (default 54484)
set -euo pipefail
cd "$(dirname "$0")/../../.."
TICKS=${1:-600}; N=${2:-200}; CONFS=${3:-ref,av_nap10}
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${IO_DATA:-/tmp/dbcraft-pg-tune-io}; PORT=${IO_PORT:-54484}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
{ echo "include '$PWD/tests/bench/tuning/conf/base.conf'"; IFS=, read -ra L <<< "$CONFS"; for c in "${L[@]}"; do echo "include '$PWD/tests/bench/tuning/conf/$c.conf'"; done; echo "track_io_timing = on"; } >> "$DATA/postgresql.conf"
: > "$DATA/log"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/integration/bench.sql -f tests/bench/tuning/steady.sql >/dev/null 2>&1
$P -c "select ibench.setup($N, 100)" -c "select mc.refresh_visibility()" -c "analyze" -c "checkpoint" >/dev/null
python3 tests/bench/tuning/steady_top.py --ticks 100 --frac 0.25 --skip 100 --csv /dev/null >/dev/null
$P -c "select pg_stat_reset_shared('io')" >/dev/null
python3 tests/bench/tuning/steady_top.py --ticks "$TICKS" --frac 0.25 --csv /tmp/dbcraft-io-lat.csv >/dev/null; rm -f /tmp/dbcraft-io-lat.csv
sleep 1
echo "pg_stat_io over $TICKS ticks (all backends; the tick loop is the only writer that matters), per tick:"
$P -F ' | ' -c "select backend_type, object, context, round(writes::numeric / $TICKS, 2) as writes_per_tick, round(extends::numeric / $TICKS, 2) as extends_per_tick, round(fsyncs::numeric / $TICKS, 3) as fsyncs_per_tick,
                       round((coalesce(write_time, 0) + coalesce(extend_time, 0) + coalesce(fsync_time, 0))::numeric / $TICKS, 3) as io_ms_per_tick
                from pg_stat_io where (writes > 0 or extends > 0 or fsyncs > 0) and backend_type in ('client backend', 'background writer', 'checkpointer', 'autovacuum worker', 'walwriter')
                order by (coalesce(write_time, 0) + coalesce(extend_time, 0) + coalesce(fsync_time, 0)) desc limit 12"
