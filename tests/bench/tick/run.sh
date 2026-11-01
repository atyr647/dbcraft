#!/usr/bin/env bash
# usage: tests/bench/tick/run.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS] [LABEL]
# env:   DBCRAFT_PGPORT (default 54411), DBCRAFT_BENCH_DB (default dbcraft), WORKLOAD=tune (the tuning trial's bots: keep-alive and teleport answers as well) or blocks (tune plus block edits every tick), TOPN=n prints the n most expensive statements (pg_stat_statements, nested) after warm-up.
# The whole server tick (net.inbox -> mc.server_tick -> drain) with the synthetic walk of tests/bench/integration/bench.sql, plus on-CPU time per tick.
# The first 20 ticks are warm-up.  The database must have its chunks generated and cached (see docs/PERF-TICK.md: the warm-up step).
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; TICKS=${4:-100}; LABEL=${5:-run}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft} PGOPTIONS="-c client_min_messages=warning"
GEN=ibench.gen; EXTRA=
if [ "${WORKLOAD:-bench}" = tune ]; then GEN=tune.gen; EXTRA='-f tests/bench/tuning/steady.sql'; fi
TAIL=; if [ "${WORKLOAD:-bench}" = blocks ]; then GEN=tickbench.gen_blocks; EXTRA='-f tests/bench/tuning/steady.sql'; TAIL='-f tests/bench/tick/blocks.sql'; fi   # blocks: tune + three block edits and some acknowledgements per tick   # tune: also answers keep-alives (every 300 ticks) and teleports like the tuning trial's bots
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql $EXTRA -f tests/bench/tick/cpu.sql $TAIL > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate tickbench.step" -c "select ibench.setup($N, $SIDE, ${VIEW:-10})" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "select count(*) from mc.refresh_visibility()" > /dev/null
# the setup deletes and re-inserts every player: start every run from the same compact tables (a long-running server reaches its own steady state)
psql -X -q -At -v ON_ERROR_STOP=1 -c "vacuum (full, analyze) mc.player, net.conn, mc.visible" > /dev/null
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
printf 'select setseed(0.99) is null;\n' > "$SCRIPT"        # the walk is the same in every run, so A/B runs see identical input
for i in $(seq 1 "$TICKS"); do
  printf 'select %s(%s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$GEN" "$FRAC"
  if [ "$i" = 20 ] && [ -n "${TOPN:-}" ]; then printf 'select pg_stat_statements_reset() is null;\n'; fi    # only needed (and only available) with TOPN
done >> "$SCRIPT"
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$SCRIPT"
psql -X -q -At -c "select tickbench.summary('$LABEL players=$N moving=$FRAC load=$(cut -d' ' -f1 /proc/loadavg)')"
if [ -n "${TREND:-}" ]; then
  psql -X -q -At -F ' ' -c "select 'trend (avg wall ms per 100 ticks after warm-up): ' || string_agg(round(a::numeric, 1)::text, '  ' order by b) from (select (tick - 21) / 100 as b, avg(wall_ms) as a from tickbench.step where tick > 20 group by 1) t" -c "select 'queue pages at the end: play_out ' || pg_relation_size('mc.play_out') / 8192 || ', net.outbox ' || pg_relation_size('net.outbox') / 8192 || ', net.inbox ' || pg_relation_size('net.inbox') / 8192 || ', mc.play_in_work ' || pg_relation_size('mc.play_in_work') / 8192"
fi
if [ -n "${TOPN:-}" ]; then
  psql -X -q -At -F ' | ' -c "select round(total_exec_time::numeric / 80, 3) as exec_ms_per_tick, round(total_plan_time::numeric / 80, 3) as plan_ms_per_tick, calls / 80 as calls_per_tick, round((total_exec_time / nullif(calls,0))::numeric, 4) as ms_per_call, rows / 80 as rows_per_tick, left(regexp_replace(query, '\s+', ' ', 'g'), 150) from pg_stat_statements where dbid = (select oid from pg_database where datname = current_database()) and query not like '%pg_stat_statements%' and query not like 'select ibench.%' and query not like 'select tickbench.%' order by (total_exec_time + total_plan_time) desc limit $TOPN"
fi
