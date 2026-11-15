#!/usr/bin/env bash
# Load the dlcraft PostgreSQL implementation (idempotent: 00_schema.sql drops and recreates schema mc).
#   pg/load.sh            apply every NN_*.sql in order
set -euo pipefail
cd "$(dirname "$0")"
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"
PSQL=${PSQL:-psql -h 127.0.0.1 -p 54340 -U postgres dlcraft -v ON_ERROR_STOP=1 -q}
for f in [0-9][0-9]_*.sql; do
  echo "load $f" >&2
  $PSQL -f "$f" -o /dev/null
done
$PSQL -c "analyze" -o /dev/null
echo "loaded" >&2
