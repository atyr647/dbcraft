#!/usr/bin/env bash
# TOAST storage modes for the chunk cache and the outbound queue, measured on a throwaway copy of the golden database: default (pglz), EXTERNAL (never compressed),
# lz4.  Prints the three steps of the chunk path (fetch, frame + queue insert, drain) for 441 chunks, best of 9, plus the size of the cache table.
# usage: tests/bench/tuning/chunkpath.sh        env: GOLD, CP_DATA (default /tmp/dbcraft-pg-tune-cp), CP_PORT (default 54474)
set -euo pipefail
cd "$(dirname "$0")/../../.."
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${CP_DATA:-/tmp/dbcraft-pg-tune-cp}; PORT=${CP_PORT:-54474}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp -c synchronous_commit=off -c jit=off' -l $DATA/log -w start" >/dev/null
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
P="psql -X -q -v ON_ERROR_STOP=1"
$P -f tests/bench/tuning/chunkpath.sql >/dev/null
$P -At -c "analyze" -c "checkpoint" >/dev/null
show() { $P -At -F ' | ' -c "select '$1: ' || step, round(best_ms::numeric, 1) || ' ms best', round(median_ms::numeric, 1) || ' ms median', pg_size_pretty(bytes) from tune.time_chunk_path(9)" -c "select '   cache table: ' || pg_size_pretty(pg_table_size('mc.chunk_cache')) || ' (heap+toast), outbox column storage ' || (select attstorage::text from pg_attribute where attrelid = 'net.outbox'::regclass and attname = 'data')"; }
show "default (pglz)   "
$P -c "alter table net.outbox alter column data set storage external" -c "alter table mc.chunk_cache alter column packet set storage external" -c "update mc.chunk_cache set packet = packet || ''::bytea" -c "vacuum full mc.chunk_cache" -c "checkpoint" >/dev/null
show "EXTERNAL         "
$P -c "alter table net.outbox alter column data set storage extended" -c "alter table net.outbox alter column data set compression lz4" -c "alter table mc.chunk_cache alter column packet set storage extended" -c "alter table mc.chunk_cache alter column packet set compression lz4" -c "update mc.chunk_cache set packet = packet || ''::bytea" -c "vacuum full mc.chunk_cache" -c "checkpoint" >/dev/null
show "lz4              "
$P -f tests/bench/tuning/apply/lockfree.sql >/dev/null
$P -c "checkpoint" >/dev/null
show "lock-free ensure_chunk_current (storage still lz4)"
