#!/usr/bin/env bash
# cell 4 of docs/WHY-MOBS-COST.md: the empty entity tick.  usage: tests/bench/mobs2/why_empty.sh [OUTFILE]      env: PGHOST PGPORT PGUSER PGDATABASE; TICKS (1000)
cd "$(dirname "$0")/../../.."
O=${1:-docs/why-mobs-results.txt}
T=${TICKS:-1000}
{
  echo "=== 4-empty-tick  ($(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg)), $T ticks per cell, round 1 then round 2 (A/B repeat)"
  for round in 1 2; do
    for p in 0 50 200; do
      for m in off inline split; do
        echo -n "round $round: "
        psql -X -q -At -v players=$p -v mode=$m -v ticks=$T -f tests/bench/mobs2/empty.sql 2>&1 | grep -E "players=|ERROR" | tail -1
      done
    done
  done
  for p in 0 200; do
    echo "--- profile inline players=$p (pg_stat_statements track=all, track_functions=all: inflates every statement by about 15-25 us)"
    psql -X -q -v players=$p -v mode=inline -v ticks=300 -v profile=1 -f tests/bench/mobs2/empty.sql 2>&1 | grep -v -E "NOTICE|^\(.* rows?\)|set_config|^-+\+?-*$|^ (all|off|0\.[0-9]+|none)( *\| *(all|none))? *$|^$"
  done
  echo "DONE empty"
} >> "$O"
