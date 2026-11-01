#!/usr/bin/env bash
# usage: tests/bench/scale/setup.sh DBNAME      (cluster from DBCRAFT_PGDATA / DBCRAFT_PGPORT, default /tmp/dbcraft-pg-scale on 54444)
# Creates a fresh database, migrates the schema, loads the reference data and the benchmark helpers.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-scale} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54444}
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres
DB=${1:?database name}
tools/pg-dev.sh start >/dev/null
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" 2>/dev/null
export PGDATABASE=$DB
tools/migrate.sh --fresh >/dev/null 2>&1
tools/load_reports.py >/dev/null
tools/load_world_ref.py >/dev/null
psql -X -q -f tests/bench/scale/helpers.sql
echo "database $DB ready"
