#!/usr/bin/env bash
# usage: tests/bench/crowd/run.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS] [LABEL]
# env:   DBCRAFT_PGPORT (default 54711), DBCRAFT_BENCH_DB (default dbcraft), TICKFN (default mc.server_tick; mc.server_tick_batched for the batched pipeline),
#        VIEW (view distance, default 10), TOPN=n prints the n most expensive statements (needs pg_stat_statements).
# A crowded world: PLAYERS bots in a square of SIDE chunks, a fraction walking straight at 4.3 blocks/s (see bench.sql).  The whole tick (net.inbox -> tick -> drain).
# The first 20 ticks are warm-up (the visible relation is built then).  STOP any running gateway on the database first: it would consume net.inbox.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-3}; FRAC=${3:-1.0}; TICKS=${4:-100}; LABEL=${5:-run}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54711} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft} PGOPTIONS="-c client_min_messages=warning"
TICKFN=${TICKFN:-mc.server_tick}
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql -f tests/bench/crowd/bench.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "select crowd.setup($N, $SIDE, ${VIEW:-10})" > /dev/null
# make sure the chunks the players can see exist and are cached (generation is not what this benchmark measures)
psql -X -q -At -v ON_ERROR_STOP=1 -c "select count(*) from mc.refresh_visibility()" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "vacuum (full, analyze) mc.player, net.conn, mc.visible" > /dev/null
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
printf 'select setseed(0.99) is null;\n' > "$SCRIPT"
for i in $(seq 1 "$TICKS"); do
  printf 'select crowd.gen(%s);\nselect crowd.timed_tick(%s);\nselect ibench.drain();\n' "$FRAC" "'$TICKFN'"
  if [ "$i" = 20 ] && [ -n "${TOPN:-}" ]; then printf 'select pg_stat_statements_reset() is null;\n'; fi
done >> "$SCRIPT"
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$SCRIPT"
psql -X -q -At -c "select crowd.summary('$LABEL $TICKFN players=$N side=$SIDE moving=$FRAC load=$(cut -d' ' -f1 /proc/loadavg)')"
psql -X -q -At -c "select 'visible pairs: ' || count(*) from mc.visible"
if [ -n "${TOPN:-}" ]; then
  psql -X -q -At -F ' | ' -c "select round(total_exec_time::numeric / $((TICKS - 20)), 3) as exec_ms_per_tick, round(total_plan_time::numeric / $((TICKS - 20)), 3) as plan_ms_per_tick, calls / $((TICKS - 20)) as calls_per_tick, rows / $((TICKS - 20)) as rows_per_tick, left(regexp_replace(query, '\s+', ' ', 'g'), 150) from pg_stat_statements where dbid = (select oid from pg_database where datname = current_database()) and query not like '%pg_stat_statements%' and query not like 'select crowd.%' and query not like 'select ibench.%' order by (total_exec_time + total_plan_time) desc limit $TOPN"
fi
