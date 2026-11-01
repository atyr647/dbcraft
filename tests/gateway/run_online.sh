#!/usr/bin/env bash
# Online-mode end-to-end test against the PL/Python reference gateway (net.run_online): database up, stub Mojang session server up, gateway up, scenarios run,
# everything stopped.  usage: tests/gateway/run_online.sh [compression_threshold]      (default -1; try 256)
# Ports: database 54555, gateway 25651, stub session server 25652.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-gw2} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54555}
THR=${1:--1}
GW=25651; STUB=25652
PSQL="psql -X -q -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft"
mkdir -p /tmp/dbcraft-gw-test
if ! $PSQL -c "select 1 from net.server_key limit 0" > /dev/null 2>&1; then tests/gateway/setup_db.sh > /tmp/dbcraft-gw-test/setup.log 2>&1; fi
$PSQL -c "update net.gateway_control set stop = false, ticks = 0, max_tick_ms = 0, late_ticks = 0; delete from net.setting where key in ('session_url','session_timeout_s'); insert into net.setting values ('session_url','http://127.0.0.1:$STUB'), ('session_timeout_s','1')"
python3 tests/gateway/stub_mojang.py $STUB > /tmp/dbcraft-gw-test/stub.log 2>&1 &
STUBPID=$!
(nohup $PSQL -c "call net.run_online($GW)" > /tmp/dbcraft-gw-test/gateway.log 2>&1 &)
cleanup() {
  $PSQL -c "update net.gateway_control set stop = true" > /dev/null 2>&1 || true
  kill $STUBPID 2> /dev/null || true
  for i in $(seq 1 40); do [ "$($PSQL -c "select count(*) from pg_stat_activity where query like 'call net.run_online%' and pid <> pg_backend_pid()")" = 0 ] && break; sleep 0.25; done
}
trap cleanup EXIT
for i in $(seq 1 60); do
  if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); s.connect(('127.0.0.1',$GW))" 2> /dev/null; then break; fi
  sleep 0.5
done
python3 tests/gateway/online_test.py $GW $STUB $DBCRAFT_PGPORT --compression "$THR"
