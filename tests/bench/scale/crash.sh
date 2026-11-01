#!/usr/bin/env bash
# Crash the scale cluster the hard way (immediate stop = no shutdown checkpoint, like a power loss for unlogged tables) and start it again.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-scale} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54444}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
su postgres -s /bin/bash -c "$PGBIN/pg_ctl -D $DBCRAFT_PGDATA -m immediate stop" >/dev/null
tools/pg-dev.sh start >/dev/null
echo "crashed and restarted"
