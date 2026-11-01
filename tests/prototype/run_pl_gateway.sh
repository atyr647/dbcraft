#!/usr/bin/env bash
# usage: run_pl_gateway.sh CONNS FRAMES_PER_TICK TICKS   (needs tools/pg-dev.sh start, ulimit -n large)
set -e; cd "$(dirname "$0")/../.."; N=$1; F=$2; T=$3; PORT=$((25600 + RANDOM % 300))
tools/pg-dev.sh psql -qtA -c "truncate net.tick_log, net.inbox, net.outbox"
(tools/pg-dev.sh psql -q -c "call net.run($PORT, $((T + 40)))" >/tmp/gw_run.log 2>&1 &)
sleep 1.2; python3 tests/prototype/pl_gateway_load.py "$N" "$PORT" "$T" "$F"; sleep 2.5
tools/pg-dev.sh psql -tA -F' | ' -c "select 'ticks='||count(*), 'conns='||max(conns), 'frames/tick='||round(avg(frames_in))::int, 'busy avg='||round(avg(busy_ms)::numeric,2)||'ms', 'p99='||round((percentile_cont(.99) within group (order by busy_ms))::numeric,2)||'ms', 'max='||round(max(busy_ms)::numeric,2)||'ms', 'db avg='||round(avg(db_ms)::numeric,2)||'ms', 'send avg='||round(avg(send_ms)::numeric,2)||'ms' from net.tick_log where frames_in>0"
