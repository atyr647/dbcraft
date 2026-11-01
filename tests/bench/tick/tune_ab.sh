#!/usr/bin/env bash
# usage: tests/bench/tick/tune_ab.sh ROUNDS TICKS "LABEL PORT DB" ["LABEL PORT DB" ...]
# The tuning trial's synthetic gateway (WORKLOAD=tune: 500 players, 25% moving, every bot answers the server's keep-alive 300 ticks after the last one and confirms teleports)
# against several (cluster, database) pairs, interleaved.  Per run: the summary line, then the three slowest ticks with their phases ("process" is where a burst of
# keep-alive answers shows up).  TICKS should exceed 320 so that the first keep-alive round (tick 300-302) is in the run.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROUNDS=$1; TICKS=$2; shift 2
SPECS=("$@")
for r in $(seq 1 "$ROUNDS"); do
  for spec in "${SPECS[@]}"; do
    read -r LABEL PORT DB <<< "$spec"
    WORKLOAD=tune DBCRAFT_PGPORT=$PORT DBCRAFT_BENCH_DB=$DB tests/bench/tick/run.sh 500 100 0.25 "$TICKS" "$LABEL" | head -1 | cut -c1-210
    PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=$DB psql -X -q -At -F ' ' -c "select '    slowest: tick ' || s.tick || ' wall ' || round(s.wall_ms::numeric, 1) || ' (process ' || round(l.ms_process::numeric, 1) || ' game ' || round(l.ms_game::numeric, 1) || ' chunks ' || round(l.ms_chunks::numeric, 1) || ' drain ' || round(l.ms_drain::numeric, 1) || ')' from tickbench.step s join mc.server_tick_log l using (tick) where s.tick > 20 order by s.wall_ms desc limit 3"
  done
done
