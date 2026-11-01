#!/usr/bin/env bash
# usage: tests/bench/tick/explain.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION OUTFILE [MIN_MS]
# Runs 25 warm-up ticks, then 3 ticks with auto_explain (nested statements, ANALYZE, BUFFERS) and writes the plans of every statement slower than MIN_MS
# (default 1 ms) found in the server log to OUTFILE.  Same setup as run.sh.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; OUT=${4:-/tmp/plans.txt}; MIN=${5:-1}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft} PGOPTIONS="-c client_min_messages=warning"
DATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-tick}
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql -f tests/bench/tick/cpu.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate tickbench.step" -c "select ibench.setup($N, $SIDE)" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "select count(*) from mc.refresh_visibility()" -c "analyze mc.player" > /dev/null
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
printf 'select setseed(0.99) is null;\n' > "$SCRIPT"
for i in $(seq 1 25); do printf 'select ibench.gen(%s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$FRAC"; done >> "$SCRIPT"
printf "load 'auto_explain';\nset auto_explain.log_min_duration = %s;\nset auto_explain.log_analyze = on;\nset auto_explain.log_buffers = on;\nset auto_explain.log_timing = on;\nset auto_explain.log_nested_statements = on;\nset auto_explain.log_format = text;\n" "$MIN" >> "$SCRIPT"
for i in 1 2 3; do printf 'select ibench.gen(%s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$FRAC"; done >> "$SCRIPT"
START=$(wc -c < "$DATA/log")
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$SCRIPT"
tail -c +"$((START + 1))" "$DATA/log" > "$OUT"
echo "plans written to $OUT ($(wc -l < "$OUT") lines)"
