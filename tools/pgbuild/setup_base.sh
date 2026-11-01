#!/usr/bin/env bash
# Build ONE warmed dbcraft database with variant B's binaries (B comes from the same source and has no dbcraft_zlib extension on its path, so the migration
# stays on the SQL deflate for every variant), then copy its data directory for A, C, D and G.  All variants therefore start from identical data.
#   usage: tools/pgbuild/setup_base.sh [VARIANTS_TO_CLONE...]   default: A B C D G (only those whose binaries exist)
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_CAPTURES=${DBCRAFT_CAPTURES:-/home/user/dbcraft/tests/fixtures/captured}
BASE=/tmp/pg-data-base
BIN=/tmp/pg-runtime-B/bin
PORT=54460
su postgres -s /bin/bash -c "rm -rf $BASE; mkdir -p $BASE"
su postgres -s /bin/bash -c "$BIN/initdb -D $BASE -A trust -E UTF8 >/dev/null"
su postgres -s /bin/bash -c "$BIN/pg_ctl -D $BASE -o '-p $PORT -k /tmp -c listen_addresses= -c fsync=off -c synchronous_commit=off -c jit=off' -l $BASE/log -w start" >/dev/null
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres
psql -X -q -d postgres -c "create database dbcraft"
export PGDATABASE=dbcraft DBCRAFT_PSQL="psql -X"
CAP=$(python3 tools/capture_to_tsv.py --path play_nocomp)
tools/migrate.sh --fresh > /dev/null
python3 tools/load_reports.py
python3 tools/load_datapack.py "$CAP"
python3 tools/load_static_packets.py "$CAP"
python3 tools/load_world_ref.py
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
select mc.configure_dev_server('pgbuild', 'creative');
update mc.server_property set value = 'peaceful' where key = 'difficulty';
-- the warm world of the benchmarks: every chunk the synthetic walk can reach, generated AND with its packet cached
select mc.generate_flat_area('minecraft:overworld', -12, -12, 172, 172);
select count(mc.chunk_packet('minecraft:overworld', x, z)) from generate_series(-12, 172) x, generate_series(-12, 172) z;
-- the area the set_block micro-benchmark edits
select mc.generate_flat_area('minecraft:overworld', 300, 300, 319, 319);
select count(mc.chunk_packet('minecraft:overworld', x, z)) from generate_series(300, 319) x, generate_series(300, 319) z;
SQL
psql -X -q -f tests/bench/runtime/micro.sql
psql -X -q -c "vacuum (analyze)" -c "checkpoint"
su postgres -s /bin/bash -c "$BIN/pg_ctl -D $BASE -m fast stop" >/dev/null
du -sh $BASE
for v in "${@:-A B C D G}"; do
  for x in $v; do
    cp -a $BASE /tmp/pg-data-$x
    rm -f /tmp/pg-data-$x/postmaster.pid
    echo "cloned base -> /tmp/pg-data-$x"
  done
done
