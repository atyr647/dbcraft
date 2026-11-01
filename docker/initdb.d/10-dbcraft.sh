#!/usr/bin/env bash
# Runs once, when the official image initialises an empty data directory (docker-entrypoint-initdb.d): builds the dbcraft database.
#
#   1. tools/migrate.sh        the schema (sql/*.sql; plus sql/optional/dev_gateway.sql when DBCRAFT_DEV_GATEWAY=1)
#   2. tools/load_reports.py   block/item/packet ids from the data generator reports mounted at $DBCRAFT_REPORTS (REQUIRED: without them the server cannot run)
#   3. the datapack registries, tags, static packets and the world reference data from a vanilla capture mounted at $DBCRAFT_CAPTURES (play_nocomp.jsonl)
#   4. mc.configure_dev_server() when the development gateway is on (offline mode, no compression)
# Mojang data is never part of the image: a missing mount is reported and the corresponding step is skipped.  Idempotent steps only; safe to re-run by hand.
set -euo pipefail
export PGUSER=${POSTGRES_USER:-postgres} PGDATABASE=${POSTGRES_DB:-postgres}
cd "${DBCRAFT_HOME:-/opt/dbcraft}"
export DBCRAFT_REPORTS=${DBCRAFT_REPORTS:-/data/reports} DBCRAFT_CAPTURES=${DBCRAFT_CAPTURES:-/data/captures}

args=()
[ "${DBCRAFT_DEV_GATEWAY:-0}" = 1 ] && args+=(--dev-gateway)
echo "dbcraft: applying the schema ${args[*]:-}"
tools/migrate.sh "${args[@]}" > /dev/null

if [ -d "$DBCRAFT_REPORTS" ] && [ -n "$(ls -A "$DBCRAFT_REPORTS" 2>/dev/null)" ]; then
  python3 tools/load_reports.py "$DBCRAFT_REPORTS"
else
  echo "dbcraft: WARNING: no generator reports mounted at $DBCRAFT_REPORTS, ref.* stays empty (see docker/README.md)"
fi

CAP=$(python3 tools/capture_to_tsv.py --path play_nocomp 2>/dev/null || true)
if [ -n "$CAP" ]; then
  python3 tools/load_datapack.py "$CAP"
  python3 tools/load_static_packets.py "$CAP"
  python3 tools/load_world_ref.py
else
  echo "dbcraft: WARNING: no capture play_nocomp.jsonl under $DBCRAFT_CAPTURES: registries, tags and the world reference data are not loaded, logins stop in configuration"
fi

if [ "${DBCRAFT_DEV_GATEWAY:-0}" = 1 ]; then
  psql -X -q -v ON_ERROR_STOP=1 -c "select mc.configure_dev_server('${DBCRAFT_MOTD:-dbcraft}', '${DBCRAFT_GAMEMODE:-survival}')" > /dev/null
fi
echo "dbcraft: database ready"
