#!/usr/bin/env bash
# cell 4b of docs/WHY-MOBS-COST.md: the empty entity tick with the early exit (sql/550) against the full tick (dbcraft.entity_empty_exit = off), same database, alternating, two rounds.
# usage: tests/bench/mobs2/why_empty2.sh [OUTFILE]      env: PGHOST PGPORT PGUSER PGDATABASE; TICKS (1000)
cd "$(dirname "$0")/../../.."
O=${1:-docs/why-mobs-results.txt}
T=${TICKS:-1000}
{
  echo "=== 4b-empty-tick-after-the-fix  ($(date -u '+%F %T') UTC, load $(cut -d' ' -f1 /proc/loadavg)), $T ticks per cell, 2 rounds, spawner off"
  for round in 1 2; do
    for p in 0 50 200; do
      for v in "off on" "inline off" "inline on" "split on"; do
        set -- $v
        echo -n "round $round: "
        psql -X -q -At -v players=$p -v mode=$1 -v exit=$2 -v ticks=$T -f tests/bench/mobs2/empty.sql 2>&1 | grep -E "players=|ERROR" | tail -1
      done
    done
  done
  echo "DONE empty2"
} >> "$O"
