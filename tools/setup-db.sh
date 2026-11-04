#!/usr/bin/env bash
# Create (or refresh) the dbcraft database on the development cluster from the cached reports and captures.  Idempotent: it does nothing when the database is
# already complete, unless --fresh.
#
# usage: tools/setup-db.sh [--fresh]
# needs: tools/bootstrap.sh has run (the generator reports and the recorded captures exist under $DBCRAFT_HOME), PostgreSQL 16.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh
FRESH=0; [ "${1:-}" = "--fresh" ] && FRESH=1

tools/pg-dev.sh start
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=dbcraft

complete() {   # the schema exists, the reference data is in, and the server is configured
  [ "$(psql -X -At -c "select count(*) from ref.block_state" 2>/dev/null || echo 0)" = 35723 ] \
  && [ "$(psql -X -At -c "select count(*) from ref.dp_node" 2>/dev/null || echo 0)" != 0 ] \
  && [ "$(psql -X -At -c "select count(*) from mc.server_property" 2>/dev/null || echo 0)" != 0 ]
}
if [ "$FRESH" = 0 ] && complete; then echo "database dbcraft is complete: nothing to do (use --fresh to rebuild)"; exit 0; fi

CAP=$(python3 tools/capture_to_tsv.py --path play_nocomp)
if [ -z "$CAP" ]; then echo "no recorded capture play_nocomp.jsonl (run tools/bootstrap.sh first)"; exit 1; fi
if [ ! -f "$DBCRAFT_REPORTS/blocks.json" ]; then echo "no generator reports in $DBCRAFT_REPORTS (run tools/bootstrap.sh first)"; exit 1; fi

# a gateway left running holds locks on the schemas about to be rebuilt
psql -X -q -At -c "select pg_terminate_backend(pid) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()" >/dev/null 2>&1 || true
DEV=""
if [ "$(psql -X -At -c "select count(*) from pg_available_extensions where name = 'plpython3u'")" != 0 ]; then DEV="--dev-gateway"; fi
echo "== migrating ${DEV:+(with the PL/Python development gateway)}"
tools/migrate.sh --fresh $DEV >/dev/null
echo "== loading reference data (generator reports)"
python3 tools/load_reports.py
echo "== loading datapack registries and tags (from the recorded capture)"
python3 tools/load_datapack.py "$CAP"
echo "== loading opaque play-entry packets"
python3 tools/load_static_packets.py "$CAP"
echo "== loading the flat world reference"
python3 tools/load_world_ref.py
echo "== loading the per-item components (attribute modifiers of worn and held items)"
python3 tools/load_item_components.py || echo "NOTE: no item components (tools/bootstrap.sh makes them): worn items add no attribute modifiers"
python3 tools/load_recipes.py
echo "== configuring the server"
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
select mc.configure_dev_server('dbcraft', 'creative');
update mc.server_property set value = '8' where key = 'view-distance';
update mc.server_property set value = '6' where key = 'simulation-distance';
update net.setting set value = 'dbcraft' where key = 'brand';
SQL
echo "database dbcraft is ready (psql -h /tmp -p $PGPORT -U postgres dbcraft)"
