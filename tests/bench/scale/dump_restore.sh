#!/usr/bin/env bash
# usage: tests/bench/scale/dump_restore.sh SOURCE_DB     full dump (custom format) and restore into a fresh database, timed; the scale/lever helper schemas are left out
set -euo pipefail
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54444} PGUSER=postgres
SRC=${1:?source database}
DUMP=/tmp/scale-restore-test.dump
t0=$(date +%s.%N)
pg_dump -d "$SRC" -N scale -N lever -Fc -f "$DUMP"
t1=$(date +%s.%N)
psql -X -q -d postgres -c "drop database if exists scale_restore" -c "create database scale_restore"
t2=$(date +%s.%N)
pg_restore -d scale_restore -j 1 "$DUMP" 2>/dev/null || true
t3=$(date +%s.%N)
size=$(( $(stat -c %s "$DUMP") / 1048576 ))
src_mb=$(psql -X -tA -d "$SRC" -c "select (pg_database_size('$SRC') / 1048576)")
chunks=$(psql -X -tA -d scale_restore -c "select count(*) from mc.chunk")
echo "dump: $(printf '%.1f' "$(echo "$t1 - $t0" | bc)") s, ${size} MB file from a ${src_mb} MB database"
echo "restore (-j 1): $(printf '%.1f' "$(echo "$t3 - $t2" | bc)") s, $chunks chunks present"
psql -X -q -d postgres -c "drop database scale_restore"
rm -f "$DUMP"
