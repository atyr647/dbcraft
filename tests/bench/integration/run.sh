#!/usr/bin/env bash
# usage: tests/bench/integration/run.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS]      e.g.  run.sh 500 100 1.0 120
# Runs the synthetic load of bench.sql through the whole server tick on the e2e database (tests/e2e/setup.sh builds it; stop the gateway first, it would tick too).
# The first 20 ticks are warm-up.  Reports the phase breakdown of mc.server_tick() against the 50 ms budget.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; TICKS=${4:-120}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54399} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft}
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/integration/bench.sql
$P -c "select ibench.setup($N, $SIDE)" > /dev/null
$P -c "select 'initial visibility build for $N players: ' || added || ' directed pairs' from mc.refresh_visibility()"
$P -c "analyze mc.player"
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
for i in $(seq 1 "$TICKS"); do printf 'select ibench.gen(%s);\nselect mc.server_tick();\nselect ibench.drain();\n' "$FRAC"; done > "$SCRIPT"
T0=$(date +%s.%N)
$P -o /dev/null -f "$SCRIPT"
echo "wall for $TICKS ticks including packet generation and drain: $(echo "$(date +%s.%N) - $T0" | bc) s   (load average $(cut -d' ' -f1 /proc/loadavg))"
$P -c "select line from ibench.summary('players=$N area=${SIDE}x${SIDE} chunks moving=$FRAC')"
$P -c "select 'visible pairs: ' || count(*) || ' (avg ' || round(count(*)::numeric / $N, 1) || ' viewers per player); errors logged: ' || (select count(*) from mc.error_log) from mc.visible"
