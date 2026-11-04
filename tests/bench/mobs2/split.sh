#!/usr/bin/env bash
# The entity connection (dbcraft.entity-mode = split, sql/550) on the mob scenarios of bench.sql.
# usage: tests/bench/mobs2/split.sh CODE LABEL OUT [TICKS]       CODE as in run_one.sh (2000v 5000n ...)       env: PGHOST PGPORT PGUSER PGDATABASE
# Population and warm-up as bench.sql (one entity tick per transaction, on this connection).  Then connection A is replaced by a stand-in that only advances mc.game_state.game_time every
# 50 ms (the player tick of an empty server costs about nothing: the point is what the ENTITY connection B costs and whether it keeps up), and B runs `call mc.entity_loop(TICKS)`.
# Prints B's tick time (wall, from mc.entity_loop_log), how many ticks it ran, the lag histogram.
set -euo pipefail
cd "$(dirname "$0")/../../.."
code=$1; label=$2; out=$3; ticks=${4:-200}
n=${code%[vnia]}; k=${code#$n}
mobs=$n; items=0; where=view
case "$k" in n) where=ring;; i) mobs=0; items=$n;; esac
psql -X -q -At -v ON_ERROR_STOP=1 -v mobs=$mobs -v items=$items -v where=$where -v ticks=20 -v label=setup -f tests/bench/mobs2/bench.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "update mc.server_property set value = 'split' where key = 'dbcraft.entity-mode'" \
     -c "update mc.game_state set game_time = (select last_tick from mc.entity_clock)" -c "truncate mc.entity_loop_log, mc.play_out" > /dev/null
psql -X -q -At -c "create or replace procedure public.mob2_clock(p_n int) language plpgsql as \$\$ begin for i in 1..p_n loop update mc.game_state set game_time = game_time + 1; commit; perform pg_sleep(0.05); end loop; end \$\$" > /dev/null
PGAPPNAME=entity_b psql -X -q -At -c "call mc.entity_loop($ticks)" > /dev/null 2>&1 &
BPID=$!
sleep 1
psql -X -q -At -c "call public.mob2_clock($((ticks + 5)))" > /dev/null
sleep 2
# B stops after TICKS ticks it RAN; when it skipped ticks (it jumps ahead when it lags) it would wait for ever for a clock that has stopped: end it, never leave it behind (it would also hold the vacuum horizon back)
psql -X -q -At -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'entity_b'" > /dev/null
wait $BPID || true
psql -X -q -At -c "update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode'" > /dev/null
res=$(psql -X -q -At -F ' ' -c "select 'B: ticks run ' || count(*) || ' of $ticks | ms wall avg ' || round(avg(ms)::numeric, 2) || ' p50 ' || round((percentile_cont(.5) within group (order by ms))::numeric, 2) || ' p99 ' || round((percentile_cont(.99) within group (order by ms))::numeric, 2) || ' max ' || round(max(ms)::numeric, 1) from mc.entity_loop_log where tick > (select min(tick) + 10 from mc.entity_loop_log)" \
      -c "select 'lag (ticks behind A at the start of B''s tick): ' || string_agg(lag || ':' || n, '  ' order by lag) from (select lag, count(*) as n from mc.entity_loop_log group by 1) q")
echo "split $label/$code | $(echo $res | tr '\n' ' ') | load $(cut -d' ' -f1 /proc/loadavg)" | tee -a "$out"
