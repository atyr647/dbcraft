#!/usr/bin/env bash
# WAL written by generating and packaging NEW chunks (a player exploring), by table, and what it would be with the derived tables UNLOGGED.
# Generates a square of chunks outside the golden world's area, fills the packet cache (mc.chunk_body_cached), and attributes the WAL with pg_waldump.
# Then repeats with mc.chunk_cache UNLOGGED (it is derived data: a miss rebuilds the packet from the chunk's rows; a crash empties it).
# usage: tests/bench/tuning/walgen.sh [SIDE=11]     env: GOLD, WG_DATA (default /tmp/dbcraft-pg-tune-wg), WG_PORT (default 54482)
set -euo pipefail
cd "$(dirname "$0")/../../.."
SIDE=${1:-11}
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${WG_DATA:-/tmp/dbcraft-pg-tune-wg}; PORT=${WG_PORT:-54482}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
run_variant() {  # $1 label  $2 sql to apply first (may be empty)  $3 first chunk coordinate  $4 extra conf name (optional)
  local label=$1 pre=$2 base=$3 extra=${4:-}
  as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
  rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
  { echo "include '$PWD/tests/bench/tuning/conf/base.conf'"; echo "include '$PWD/tests/bench/tuning/conf/ref.conf'"; [ -n "$extra" ] && echo "include '$PWD/tests/bench/tuning/conf/$extra.conf'"; true; } >> "$DATA/postgresql.conf"
  : > "$DATA/log"
  as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
  export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
  local P="psql -X -q -At -v ON_ERROR_STOP=1"
  [ -n "$pre" ] && $P -c "$pre" >/dev/null
  $P -c "checkpoint" >/dev/null
  L0=$($P -c "select pg_current_wal_lsn()")
  T0=$(date +%s%N)
  $P -c "select count(*) from (select mc.generate_flat('minecraft:overworld', x, z) from generate_series($base, $base + $SIDE - 1) x, generate_series($base, $base + $SIDE - 1) z) g" >/dev/null
  $P -c "select count(mc.chunk_body_cached('minecraft:overworld', x, z)) from generate_series($base, $base + $SIDE - 1) x, generate_series($base, $base + $SIDE - 1) z" >/dev/null
  MS=$(( ($(date +%s%N) - T0) / 1000000 ))
  L1=$($P -c "select pg_current_wal_lsn()")
  N=$((SIDE * SIDE))
  BYTES=$($P -c "select pg_wal_lsn_diff('$L1', '$L0')")
  echo "== $label: $N chunks generated and packaged in $MS ms; WAL $(( BYTES / 1024 )) KB total, $(( BYTES / N )) bytes per chunk"
  python3 tests/bench/tuning/walstat.py "$DATA" "$L0" "$L1" "$PORT" | sed -n '/top relations/,$p' | head -9
  as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true
  rm -rf "$DATA"
}
run_variant "mc.chunk_cache logged (status quo)" "" 300
run_variant "mc.chunk_cache UNLOGGED" "alter table mc.chunk_cache set unlogged" 300
run_variant "wal_compression = lz4" "" 300 wal_lz4
run_variant "wal_compression = on (pglz)" "" 300 wal_comp
