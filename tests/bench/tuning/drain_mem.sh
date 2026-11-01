#!/usr/bin/env bash
# work_mem and the outbound drain during a join storm: net.drain_outbox() aggregates every connection's frames with an ordered string_agg, so the sort needs memory in
# proportion to the bytes queued for ALL connections.  A burst of joins (each about 3.3 MB of chunk packets at view distance 9) can exceed work_mem and spill to temp files.
# Fills net.outbox with CONNS x FRAMES frames of 7 KB (a joiner's chunk batch) and times the drain for several work_mem values.
# usage: tests/bench/tuning/drain_mem.sh [CONNS=20] [FRAMES=441]     env: GOLD, DM_DATA (default /tmp/dbcraft-pg-tune-dm), DM_PORT (default 54478)
set -euo pipefail
cd "$(dirname "$0")/../../.."
CONNS=${1:-20}; FRAMES=${2:-441}
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${DM_DATA:-/tmp/dbcraft-pg-tune-dm}; PORT=${DM_PORT:-54478}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
{ echo "include '$PWD/tests/bench/tuning/conf/base.conf'"; echo "include '$PWD/tests/bench/tuning/conf/ref.conf'"; } >> "$DATA/postgresql.conf"
: > "$DATA/log"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
P="psql -X -q -At -v ON_ERROR_STOP=1"
echo "$CONNS connections x $FRAMES frames of about 7 KB = about $(( CONNS * FRAMES * 7 / 1024 )) MB queued, then net.drain_outbox():"
for wm in 4MB 16MB 64MB 256MB; do
  $P -c "truncate net.outbox" >/dev/null
  $P -c "insert into net.outbox (conn_id, data) select c, decode(repeat(md5((c * 100000 + f)::text), 224), 'hex') from generate_series(1, $CONNS) c, generate_series(1, $FRAMES) f" >/dev/null
  $P -c "select pg_stat_reset()" >/dev/null
  RES=$($P -c "set work_mem = '$wm'" -c "\\timing on" -c "select count(*), sum(length(data)) from net.drain_outbox()" 2>&1 | grep -E "Time:" | sed 's/Time: //')
  sleep 1
  TF=$($P -F ' ' -c "select temp_files, pg_size_pretty(temp_bytes) from pg_stat_database where datname = 'dbcraft'")
  printf '  work_mem %-6s drain %-16s temp files / bytes: %s\n' "$wm" "$RES" "$TF"
done
