#!/usr/bin/env bash
# The gateway tests' own database: a PostgreSQL cluster on port 54555 (data /tmp/dbcraft-pg-gw2), the schema with the development gateways, reference data and
# a dev-server configuration.  A thin wrapper around tests/e2e/setup.sh with its own ports so it never touches another cluster.
# needs: see tests/e2e/setup.sh (plpython3u, the data generator reports, one vanilla capture with the configuration phase: DBCRAFT_CAPTURES)
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-gw2} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54555}
export DBCRAFT_CAPTURES=${DBCRAFT_CAPTURES:-/home/user/dbcraft/tests/fixtures/captured}
exec tests/e2e/setup.sh
