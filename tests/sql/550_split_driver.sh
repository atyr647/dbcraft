#!/usr/bin/env bash
# usage: 550_split_driver.sh TICKS      (environment: PGHOST PGPORT PGUSER PGDATABASE, as exported by the test runners)
# Two REAL connections in lockstep, used by tests/sql/550_entity_split.sql: for every tick k, connection A (a fresh psql session) runs t.a_tick(k) - the clock, the scripted block
# changes, mc.entity_step(k) - and commits; then connection B (another fresh session) runs mc.entity_tick(k) the way mc.entity_loop() does, after telling it which tick it ran last
# (the loop keeps that in its session; a fresh session per tick must set it).  Nothing is shared but the database.
set -euo pipefail
N=${1:-20}
for k in $(seq 1 "$N"); do
  psql -X -q -At -v ON_ERROR_STOP=1 -c "select t.a_tick($k)" > /dev/null
  psql -X -q -At -v ON_ERROR_STOP=1 -c "select set_config('dbcraft.entity_tick', '$((k - 1))', false)" -c "select mc.entity_tick($k)" > /dev/null
done
