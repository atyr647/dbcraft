#!/usr/bin/env bash
# Generate the world the capacity bench walks in (chunks -R..R, packets cached) in the database DBCRAFT_BENCH_DB, then make it a template: createdb -T of it gives a fresh copy for every experiment.
# usage: tests/bench/capacity/world.sh [R]   (default 70: the area of 500 players over 100 x 100 chunks plus the view radius)
set -euo pipefail
cd "$(dirname "$0")/../../.."
R=${1:-70}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft}
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql -f tests/bench/tick/cpu.sql -f tests/bench/capacity/bench.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate mc.chunk cascade" -c "select capb.world($R)" -c "checkpoint" > /dev/null
psql -X -q -At -c "select count(*) || ' chunks, ' || (select count(*) from mc.chunk_cache) || ' cached packets' from mc.chunk"
