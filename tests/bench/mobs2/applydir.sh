#!/usr/bin/env bash
# apply the entity sql files from a directory (default: sql/) to a database: applydir.sh DB [DIR]       env: PGHOST PGPORT PGUSER
cd "$(dirname "$0")/../../.."
export PGHOST=${PGHOST:-/tmp} PGPORT=${PGPORT:-57411} PGUSER=${PGUSER:-postgres} PGDATABASE=$1
dir=${2:-sql}
for f in 510_entity_physics 541_entity_lanes 550_entity_split 551_entity_fanout 940_entity_auto_lanes; do
  psql -X -q -v ON_ERROR_STOP=1 -f $dir/$f.sql 2>&1 | grep -v NOTICE
done
