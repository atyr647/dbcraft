#!/usr/bin/env bash
# tests/bench/mobs2/idle.sh PLAYERS...   : the idle cost of dbcraft.entity-mode off | inline | split (nothing to simulate), alternating, 3 rounds     env: PGHOST PGPORT PGUSER PGDATABASE
cd "$(dirname "$0")/../../.."
for round in 1 2 3; do
  for p in "$@"; do
    for m in off inline split; do
      echo -n "round $round: "
      psql -X -q -At -v players=$p -v mode=$m -v ticks=${TICKS:-300} -f tests/bench/mobs2/idle.sql 2>&1 | grep -E "players=|ERROR" | tail -1
    done
  done
done
psql -X -q -c "update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode'" -c "delete from mc.player" > /dev/null
