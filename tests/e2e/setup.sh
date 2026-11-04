#!/usr/bin/env bash
# Stand up a complete dbcraft server database for the end-to-end tests: its own PostgreSQL cluster (port 54399, data in /tmp/dbcraft-pg-int), the schema
# with the development gateway, the reference data, and a dev-server configuration.  Idempotent: it rebuilds the dbcraft schemas every time.
#
# usage: tests/e2e/setup.sh                      environment: DBCRAFT_PGDATA, DBCRAFT_PGPORT, DBCRAFT_CAPTURES, DBCRAFT_REPORTS
# needs: PostgreSQL 16 with plpython3u (postgresql-plpython3-16), python3, the data generator reports (DBCRAFT_REPORTS) and ONE vanilla capture that
#        includes the configuration phase (tools/capture_vanilla.py > tests/fixtures/captured/play_nocomp.jsonl): the datapack registries, tags and a few
#        opaque packets (recipes, commands, advancements) are read from it at load time.  Mojang data is never committed.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-int} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54399}
tools/pg-dev.sh start
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=dbcraft
CAP=$(python3 tools/capture_to_tsv.py --path play_nocomp)
if [ -z "$CAP" ]; then echo "no capture play_nocomp.jsonl found (see the header of this script)"; exit 1; fi
# a gateway left running from an earlier session holds locks on the schemas about to be rebuilt
psql -X -q -At -c "select pg_terminate_backend(pid) from pg_stat_activity where query like 'call net.run%' and pid <> pg_backend_pid()" > /dev/null 2>&1 || true
tools/migrate.sh --fresh --dev-gateway > /dev/null
python3 tools/load_reports.py
python3 tools/load_datapack.py "$CAP"
python3 tools/load_static_packets.py "$CAP"
python3 tools/load_world_ref.py
python3 tools/load_dynamics.py
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
select mc.configure_dev_server('dbcraft e2e', 'creative');
update mc.server_property set value = '2'        where key in ('view-distance', 'simulation-distance');
update mc.server_property set value = 'peaceful' where key = 'difficulty';
update mc.server_property set value = '10'       where key = 'max-players';
update net.setting set value = 'dbcraft' where key = 'brand';
SQL
echo "dbcraft e2e database ready: psql -h /tmp -p $PGPORT -U postgres dbcraft"
