#!/usr/bin/env bash
# Load test of the Rust gateway: N simulated clients (tests/gateway/load_clients.py) against a fresh gateway on port 25651 and the cluster on 54655.
# usage: tests/gateway/run_load_rust.sh N [PROCS=4] [SECONDS=20] [INBOX_MODE=copy]
# Reports: gateway CPU (utime+stime from /proc over the steady window), Postgres CPU (all postgres processes of the cluster), RSS, tick stats, probe latency.
set -uo pipefail
cd "$(dirname "$0")/../.."
N=${1:-500}; PROCS=${2:-4}; SECS=${3:-20}; MODE=${4:-copy}
PGPORT=${DBCRAFT_PGPORT:-54655}
PSQL="psql -X -At -h /tmp -p $PGPORT -U postgres dbcraft"
OUT=/tmp/dbcraft-load-$N-$MODE
mkdir -p "$OUT"
ulimit -n 20000
export DBCRAFT_GW_DATABASE_URL="host=/tmp port=$PGPORT user=postgres dbname=dbcraft"
export DBCRAFT_GW_LISTEN=127.0.0.1:25651
export DBCRAFT_GW_MAX_CONNECTIONS_PER_IP=0 DBCRAFT_GW_NEW_CONNECTIONS_PER_IP_PER_SEC=0 DBCRAFT_GW_LOGIN_ATTEMPTS_PER_IP_PER_MIN=0
export DBCRAFT_GW_INBOX_MODE=$MODE
$PSQL -c "update net.gateway_control set stop=false" >/dev/null 2>&1
$PSQL -c "update mc.server_property set value='100000' where key='max-players'" >/dev/null 2>&1   # the 20-player cap would refuse the clients
gateway/target/dbcraft-gateway > "$OUT/gateway.log" 2>&1 &
GW=$!
trap 'kill -TERM $GW 2>/dev/null; wait $GW 2>/dev/null' EXIT
sleep 1
cpu() { awk '{print $14+$15}' /proc/$1/stat; }                      # clock ticks
PM=$(head -1 /tmp/dbcraft-pg-gw3/postmaster.pid)
pgcpu() { local t=0; for p in $PM $(pgrep -P $PM); do t=$((t + $(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0))); done; echo $t; }
echo "uptime before: $(uptime)"
python3 tests/gateway/load_clients.py 25651 "$N" --procs "$PROCS" --seconds "$((SECS + 90))" --ramp 400 --moving "${MOVING:-0.2}" > "$OUT/clients.json" 2> "$OUT/clients.err" &
LC=$!
# wait until all joined (connections stat) or the generator finished, then sample the steady window
while kill -0 $LC 2>/dev/null; do
  c=$($PSQL -c "select connections from net.gateway_stats order by ts desc limit 1" 2>/dev/null)
  if [ "${c:-0}" -ge $((N * 95 / 100)) ]; then break; fi
  sleep 1
done
# the join storm (every client's registry + chunk burst) is a one-off cost reported separately; measure the steady state:
# wait until the last 3 stats rows all have an average tick under 100 ms
for _ in $(seq 1 60); do
  kill -0 $LC 2>/dev/null || break
  ok=$($PSQL -c "select count(*) = 3 and bool_and(tick_ms_avg < 100 and connections >= $N * 95 / 100) from (select * from net.gateway_stats order by ts desc limit 3) s" 2>/dev/null)
  [ "$ok" = "t" ] && break
  sleep 1
done
c=$($PSQL -c "select connections from net.gateway_stats order by ts desc limit 1")
RSS_KB=$(awk '/VmRSS/{print $2}' /proc/$GW/status)
C0=$(cpu $GW); P0=$(pgcpu); T0=$(date +%s.%N)
S0=$($PSQL -c "select coalesce(max(ts), now()) from net.gateway_stats")
sleep "$SECS"
C1=$(cpu $GW); P1=$(pgcpu); T1=$(date +%s.%N)
HZ=$(getconf CLK_TCK)
echo "uptime during: $(uptime)"
echo "gateway: RSS $RSS_KB kB for $c connections = $((RSS_KB / (c > 0 ? c : 1))) kB/conn"
awk -v a=$C0 -v b=$C1 -v t0=$T0 -v t1=$T1 -v hz=$HZ 'BEGIN{printf "gateway CPU: %.1f%% of one core\n", (b-a)/hz/(t1-t0)*100}'
awk -v a=$P0 -v b=$P1 -v t0=$T0 -v t1=$T1 -v hz=$HZ 'BEGIN{printf "postgres CPU (all cluster procs): %.1f%% of one core\n", (b-a)/hz/(t1-t0)*100}'
$PSQL -c "select 'ticks/s avg ' || round(avg(ticks)::numeric,1) || ', tick_ms avg ' || round(avg(tick_ms_avg)::numeric,2) || ', max ' || round(max(tick_ms_max)::numeric,1) || ', late ticks ' || sum(late_ticks) || ', errors ' || sum(errors) || ', conns ' || max(connections) from net.gateway_stats where ts > '$S0'"
wait $LC
cat "$OUT/clients.err"
cat "$OUT/clients.json"
