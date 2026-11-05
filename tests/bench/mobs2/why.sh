#!/usr/bin/env bash
# docs/WHY-MOBS-COST.md: one scenario twice, once without instrumentation (CPU), once with pg_stat_statements + track_functions (profile).
# usage: tests/bench/mobs2/why.sh NAME OUTFILE [bench.sql -v args...]       env: PGHOST PGPORT PGUSER PGDATABASE; TICKS (60), WARM (150)
cd "$(dirname "$0")/../../.."
name=$1; out=$2; shift 2
{
  echo "=== $name  ($(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg))"
  echo "--- cpu run (no instrumentation)"
  psql -X -q -At -v ON_ERROR_STOP=1 -v ticks=${TICKS:-60} -v warm=${WARM:-150} -v label=$name "$@" -f tests/bench/mobs2/bench.sql 2>&1 | grep -E "cpu ms avg|ERROR"
  echo "--- profile run (pg_stat_statements track=all, track_functions=all: about +30 % CPU)"
  psql -X -q -v ON_ERROR_STOP=1 -v ticks=${TICKS:-60} -v warm=${WARM:-150} -v label=$name -v profile=1 "$@" -f tests/bench/mobs2/bench.sql 2>&1 | grep -v -E "NOTICE|^\(.* rows?\)|set_config|^-+\+?-*$|^ (all|off|0\.[0-9]+|none)( *\| *(all|none))? *$|^$"
} >> "$out"
