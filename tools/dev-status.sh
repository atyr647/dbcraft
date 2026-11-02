#!/usr/bin/env bash
# What is running?   usage: tools/dev-status.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=dbcraft
if psql -X -q -At -c "select 1" >/dev/null 2>&1; then
  echo "database:  running (port $DBCRAFT_PGPORT, data $DBCRAFT_PGDATA)"
  psql -X -q -At -F ' | ' -c "select 'loaded: '||(select count(*) from ref.block_state)||' block states', (select count(*) from mc.chunk)||' chunks', (select count(*) from mc.player where conn_id is not null)||' players online'" 2>/dev/null
else echo "database:  not running"; fi
if [ -f "$DBCRAFT_RUN/gateway.pid" ] && kill -0 "$(cat "$DBCRAFT_RUN/gateway.pid")" 2>/dev/null; then
  echo "gateway:   running ($(cat "$DBCRAFT_RUN/gateway.kind" 2>/dev/null || echo "?"), pid $(cat "$DBCRAFT_RUN/gateway.pid"), port $DBCRAFT_PORT, log $DBCRAFT_LOG/gateway.log)"
  psql -X -q -At -F ' | ' -c "select 'ticks='||ticks, 'last_tick_ms='||round(last_tick_ms::numeric,2), 'max_tick_ms='||round(max_tick_ms::numeric,2), 'late='||late_ticks, 'connections='||connections from net.gateway_control" 2>/dev/null
else echo "gateway:   not running"; fi
