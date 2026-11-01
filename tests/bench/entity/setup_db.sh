#!/usr/bin/env bash
# Stand up a database for the entity benchmarks: own cluster (DBCRAFT_PGDATA/DBCRAFT_PGPORT), schema, reference data, a dev-server configuration.
# usage: DBCRAFT_PGDATA=/tmp/dbcraft-pg-mob DBCRAFT_PGPORT=54611 tests/bench/entity/setup_db.sh [dbname]
set -euo pipefail
cd "$(dirname "$0")/../../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-mob} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54611}
DB=${1:-dbcraft}
tools/pg-dev.sh start
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
export PGDATABASE=$DB
CAP=$(python3 tools/capture_to_tsv.py --path play_nocomp)
tools/migrate.sh --fresh > /dev/null 2>&1
python3 tools/load_reports.py > /dev/null
python3 tools/load_datapack.py "$CAP" > /dev/null
python3 tools/load_static_packets.py "$CAP" > /dev/null
python3 tools/load_world_ref.py > /dev/null
psql -X -q -c "select mc.block_class_refresh()" > /dev/null
psql -X -q -v ON_ERROR_STOP=1 -c "select mc.configure_dev_server('mob bench', 'creative')" -c "update mc.server_property set value = '3' where key in ('view-distance', 'simulation-distance')" > /dev/null
echo "ready: psql -h /tmp -p $PGPORT -U postgres $DB"
