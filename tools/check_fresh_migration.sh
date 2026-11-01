#!/usr/bin/env bash
# Structural checks on a CLEAN migration (the test suite runs files that reinstall functions, so it cannot see which definition a fresh install ends with).
# usage: tools/check_fresh_migration.sh      uses the dev cluster; creates and drops database dbcraft_fresh
set -euo pipefail
cd "$(dirname "$0")/.."
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres
psql -X -q -d postgres -c "drop database if exists dbcraft_fresh" -c "create database dbcraft_fresh" 2>/dev/null
PGDATABASE=dbcraft_fresh tools/migrate.sh --fresh >/dev/null
fail=0
check() {  # name, sql returning true
  if [ "$(psql -X -d dbcraft_fresh -tA -c "$2")" = "t" ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
def="pg_get_functiondef('net.stream_chunks()'::regprocedure)"
check "net.stream_chunks requests chunks (async queue), not inline generation" "select position('want_chunks' in $def) > 0 and position('generate_flat' in $def) = 0"
check "net.stream_chunks delivers through mc.deliver_ready_chunks"            "select position('deliver_ready_chunks' in $def) > 0"
check "net.stream_chunks uses arrays, not a temp table"                       "select position('create temp table' in $def) = 0"
# per-tick relation churn (docs/PERF-TICK.md): a clean migration must end with the versions of these functions that keep their per-tick sets in arrays
for f in 'mc.deliver_ready_chunks()' 'mc.broadcast_block_events()' 'mc.server_tick()' 'mc.tick_core()' 'net.process_fast()' 'mc.apply_player_moves(bigint)' 'mc.refresh_visibility()'; do
  check "$f creates no temp table" "select position('create temp table' in lower(pg_get_functiondef('$f'::regprocedure))) = 0"
done
check "net.process_fast answers keep-alives in bulk"  "select position('keepalive_id = case' in pg_get_functiondef('net.process_fast()'::regprocedure)) > 0"
psql -X -q -d postgres -c "drop database dbcraft_fresh"
exit $fail
