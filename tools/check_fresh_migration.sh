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
# the login path (sql/460-463): a later file must not undo it
check "proto.varint_read is PL/pgSQL (the SQL one is re-planned per call)"    "select l.lanname = 'plpgsql' from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'proto.varint_read(bytea,integer)'::regprocedure"
check "proto.string_read is PL/pgSQL"                                         "select l.lanname = 'plpgsql' from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'proto.string_read(bytea,integer)'::regprocedure"
check "net.send(bigint,integer,bytea) is PL/pgSQL"                            "select l.lanname = 'plpgsql' from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'net.send(bigint,integer,bytea)'::regprocedure"
check "net.send_config_data serves the cached burst"                          "select position('config_burst' in prosrc) > 0 from pg_proc where oid = 'net.send_config_data(bigint,text[])'::regprocedure"
check "net.hook_join_info asks mc.on_join for no rows for the joiner"         "select position('c.name, false)' in prosrc) > 0 and position('delete from mc.play_out' in prosrc) = 0 from pg_proc where oid = 'net.hook_join_info(bigint)'::regprocedure"
check "net.outbox.data is stored uncompressed (EXTERNAL)"                     "select attstorage = 'e' from pg_attribute where attrelid = 'net.outbox'::regclass and attname = 'data'"
check "net.player_info_body reads the cached tab-entry heads"                 "select position('conn_tab' in prosrc) > 0 from pg_proc where oid = 'net.player_info_body(bigint[])'::regprocedure"
check "net.config_begin serves the cached start of the configuration phase"   "select position('config_begin_cache' in prosrc) > 0 from pg_proc where oid = 'net.config_begin(bigint)'::regprocedure"
check "net.handle plans once (plan_cache_mode = force_generic_plan)"          "select coalesce(proconfig @> array['plan_cache_mode=force_generic_plan'], false) from pg_proc where oid = 'net.handle(bigint,bytea)'::regprocedure"
psql -X -q -d postgres -c "drop database dbcraft_fresh"
exit $fail
