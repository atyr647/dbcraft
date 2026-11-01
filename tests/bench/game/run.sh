#!/usr/bin/env bash
# usage: tests/bench/game/run.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS]      e.g.  run.sh 500 100 1.0 120
# Needs a migrated database (tests/sql/run.sh builds one); loads the bench helper functions itself.  Every statement is its own transaction, like the
# real server.  Reports the phase breakdown of mc.tick() from mc.tick_log (the first 20 ticks are warm-up) against the 50 ms budget.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; TICKS=${4:-120}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_TESTDB:-dbcraft_game}
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/game/bench.sql
$P -c "truncate bench.step" -c "select bench.setup($N, $SIDE)" > /dev/null
S0=$(date +%s.%N)
$P -c "select 'initial visibility build for $N players: ' || added || ' directed pairs' from mc.refresh_visibility()"
echo "  took $(echo "$(date +%s.%N) - $S0" | bc) s"
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
for i in $(seq 1 "$TICKS"); do printf 'select bench.gen(%s);\nselect mc.tick();\nselect bench.drain();\n' "$FRAC"; done > "$SCRIPT"
T0=$(date +%s.%N)
$P -o /dev/null -f "$SCRIPT"
echo "wall for $TICKS ticks including packet generation and drain: $(echo "$(date +%s.%N) - $T0" | bc) s   (load average $(cut -d' ' -f1 /proc/loadavg))"
$P -c "select line from bench.summary('players=$N area=${SIDE}x${SIDE} chunks moving=$FRAC')"
$P -c "select 'visible pairs: ' || count(*) || ' (avg ' || round(count(*)::numeric / $N, 1) || ' viewers per player)' from mc.visible"
