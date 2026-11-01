#!/usr/bin/env bash
# usage: tests/bench/inline/run_funcs.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS] > funcs.csv
# env:   DBCRAFT_PGPORT (default 54329), DBCRAFT_BENCH_DB (default dbcraft_inl_bench)
# The standard tick benchmark (tests/bench/tick/run.sh: net.inbox -> mc.server_tick -> drain, the synthetic walk, warm world) with track_functions = all.
# The statistics are reset after 20 warm-up ticks; the output is, per function the tick CALLS (inlined functions never appear: they are not calls):
#   name, nargs, language, volatility, calls_per_tick, total_ms_per_tick (includes callees), self_ms_per_tick, self_us_per_call
# Feed the file to  tools/audit_inlining.py --hot-stats  to rank the not-inlined functions by what they cost.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; TICKS=${4:-100}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft_inl_bench}
export PGOPTIONS="-c client_min_messages=warning -c track_functions=all"
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql -f tests/bench/tick/cpu.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate tickbench.step" -c "select ibench.setup($N, $SIDE, ${VIEW:-10})" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "select count(*) from mc.refresh_visibility()" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "vacuum (full, analyze) mc.player, net.conn, mc.visible" > /dev/null
SCRIPT=$(mktemp); OUT=$(mktemp); trap 'rm -f "$SCRIPT" "$OUT"' EXIT
printf 'select setseed(0.99) is null;\n' > "$SCRIPT"
for i in $(seq 1 "$TICKS"); do
  printf 'select ibench.gen(%s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$FRAC"
  if [ "$i" = 20 ]; then printf 'select pg_stat_reset() is null;\n'; fi
done >> "$SCRIPT"
printf 'select pg_stat_force_next_flush();\nselect pg_sleep(0.2);\n' >> "$SCRIPT"
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$SCRIPT"
# stats of the session that issued pg_stat_reset() are flushed after it: normalise by the number of ticks the counters really contain
MEASURED="(select calls from pg_stat_user_functions where funcid = 'mc.server_tick()'::regprocedure)"
psql -X -q --csv -v ON_ERROR_STOP=1 -c "select n.nspname || '.' || p.proname as name, p.pronargs as nargs, l.lanname as lang, case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end as volatility, round(s.calls::numeric / $MEASURED, 2) as calls_per_tick, round((s.total_time / $MEASURED)::numeric, 4) as total_ms_per_tick, round((s.self_time / $MEASURED)::numeric, 4) as self_ms_per_tick, round((s.self_time / nullif(s.calls, 0) * 1000)::numeric, 2) as self_us_per_call from pg_stat_user_functions s join pg_proc p on p.oid = s.funcid join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang order by s.total_time desc"
