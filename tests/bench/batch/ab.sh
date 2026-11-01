#!/usr/bin/env bash
# Interleaved A/B runs of whole-tick implementations on identical deterministic input.
#   usage: tests/bench/batch/ab.sh "base batched" PLAYERS SIDE_CHUNKS MOVING_FRACTION MODE TXMODE TICKS ROUNDS [FLAGS]
#   e.g.   tests/bench/batch/ab.sh "base batched" 500 100 1.0 dither split 80 5
# Needs the benchmark database prepared like docs/PERF-BATCH.md says (cluster :54422, database dbbench, warm world).  Environment: DBCRAFT_PGPORT, DBCRAFT_BENCH_DB.
# For each round, each implementation gets a fresh ibench.setup (same seed) and runs TICKS ticks (the first 20 are warm-up); impls alternate A B A B ...
# FLAGS (optional) is written to the GUC mc.batch_flags before each 'batched' run (component switches, see sql/380_batch_pipeline.sql).
set -euo pipefail
cd "$(dirname "$0")/../../.."
IMPLS=${1:-"base batched"}; N=${2:-500}; SIDE=${3:-100}; FRAC=${4:-1.0}; MODE=${5:-dither}; TX=${6:-split}; TICKS=${7:-80}; ROUNDS=${8:-5}; FLAGS=${9:-}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54422} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbbench}
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/batch/bench.sql > /dev/null 2>&1
run=0
for round in $(seq 1 "$ROUNDS"); do
  for impl in $IMPLS; do
    run=$((run + 1))
    $P -c "select ibench.setup($N, $SIDE)" -c "select count(*) from mc.refresh_visibility()" -c "analyze mc.player" -c "vacuum mc.player, mc.visible" > /dev/null
    [ -n "$FLAGS" ] && $P -c "alter database $PGDATABASE set mc.batch_flags = '$FLAGS'" > /dev/null || $P -c "alter database $PGDATABASE reset mc.batch_flags" > /dev/null
    sleep 1.3
    S0=$($P -c "select coalesce(sum(n_tup_ins),0)||' '||coalesce(sum(n_tup_upd),0)||' '||coalesce(sum(n_tup_del),0)||' '||coalesce(sum(n_tup_hot_upd),0) from pg_stat_user_tables where schemaname in ('mc','net')")
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    $P -c "call bbench.run($run, '$impl', $TICKS, $FRAC, '$MODE', '$TX')"
    sleep 1.5
    S1=$($P -c "select coalesce(sum(n_tup_ins),0)||' '||coalesce(sum(n_tup_upd),0)||' '||coalesce(sum(n_tup_del),0)||' '||coalesce(sum(n_tup_hot_upd),0) from pg_stat_user_tables where schemaname in ('mc','net')")
    STM=$($P -c "select coalesce(sum(calls),0) from pg_stat_statements where dbid = (select oid from pg_database where datname = current_database()) and query not ilike '%pg_stat_statements%' and query not ilike '%bbench.%'")
    read -r i0 u0 d0 h0 <<< "${S0//|/ }"; read -r i1 u1 d1 h1 <<< "${S1//|/ }"
    MEAS=$((TICKS - 20))
    $P -c "update bbench.run_log set statements = $STM, rows_ins = $((i1 - i0)), rows_upd = $((u1 - u0)), rows_del = $((d1 - d0)), hot_upd = $((h1 - h0)) where run_id = $run"
    echo "round $round load $LOAD | $($P -c "select line from bbench.summary($run)")"
  done
done
echo "---- medians over $ROUNDS rounds ($N players, side $SIDE, moving $FRAC, $MODE, tx=$TX, flags='${FLAGS}')"
$P -F' | ' -c "
with per as (select r.run_id, r.impl, avg(s.tick_ms) avg_ms, percentile_cont(.5) within group (order by s.tick_ms) p50, percentile_cont(.99) within group (order by s.tick_ms) p99, max(s.tick_ms) mx,
                    avg(s.drain_ms) drain, avg(s.bytes_out)/1024 kb, avg(s.frames_out) fr, r.wal_bytes/($TICKS-20.0)/1024 wal, r.statements/($TICKS-20.0) stm,
                    r.rows_ins/($TICKS-20.0) ri, r.rows_upd/($TICKS-20.0) ru, r.rows_del/($TICKS-20.0) rd, r.hot_upd::float8/nullif(r.rows_upd,0) hot
             from bbench.step s join bbench.run_log r using (run_id) where s.tick > 20 group by r.run_id, r.impl, r.wal_bytes, r.statements, r.rows_ins, r.rows_upd, r.rows_del, r.hot_upd)
select impl, count(*) runs, 'avg ' || round((percentile_cont(.5) within group (order by avg_ms))::numeric, 2) || ' ms', 'p50 ' || round((percentile_cont(.5) within group (order by p50))::numeric, 2),
       'p99 ' || round((percentile_cont(.5) within group (order by p99))::numeric, 2), 'max ' || round((percentile_cont(.5) within group (order by mx))::numeric, 1),
       'drain ' || round((percentile_cont(.5) within group (order by drain))::numeric, 2), 'KB/tick ' || round((percentile_cont(.5) within group (order by kb))::numeric, 1),
       'WAL KB/tick ' || round((percentile_cont(.5) within group (order by wal))::numeric, 1), 'stmts/tick ' || round((percentile_cont(.5) within group (order by stm))::numeric, 1),
       'rows ins/upd/del per tick ' || round((percentile_cont(.5) within group (order by ri))::numeric) || '/' || round((percentile_cont(.5) within group (order by ru))::numeric) || '/' || round((percentile_cont(.5) within group (order by rd))::numeric),
       'hot% ' || round((100 * percentile_cont(.5) within group (order by hot))::numeric)
from per group by impl order by impl"
