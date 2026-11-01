#!/usr/bin/env bash
# The offline end-to-end comparisons of tests/e2e/run_all.sh, run against the RUST gateway (gateway/target/dbcraft-gateway) instead of the PL/Python development gateway:
# real clients join, build, walk and chat over TCP; what they receive is compared with the recordings of the real vanilla 26.3 server.
#
# usage: tests/gateway/run_e2e_rust.sh [--no-setup]
# environment: DBCRAFT_RUST_GATEWAY (binary), DBCRAFT_E2E_DIR (vanilla recordings, read only, default /tmp/dbcraft-e2e), DBCRAFT_GW_OUT (our recordings, default /tmp/dbcraft-e2e-gw3),
#              DBCRAFT_PGDATA / DBCRAFT_PGPORT (default /tmp/dbcraft-pg-gw3 and 54655: its own cluster), GW_PORT (default 25651)
# Needs the database built by tests/gateway/setup_db.sh (run it with the same DBCRAFT_PGDATA/DBCRAFT_PGPORT; this script does so unless --no-setup).
set -uo pipefail
cd "$(dirname "$0")/../.."
GWBIN=${DBCRAFT_RUST_GATEWAY:-gateway/target/dbcraft-gateway}
VAN=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e}
OUT=${DBCRAFT_GW_OUT:-/tmp/dbcraft-e2e-gw3}
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-gw3} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54655}
PORT=${GW_PORT:-25651}
mkdir -p "$OUT"
for f in vanilla_join_returning.jsonl vanilla_block_actor.jsonl vanilla_move6.jsonl vanilla_social_first.jsonl; do
  [ -f "$VAN/$f" ] || { echo "missing $VAN/$f: run tests/e2e/record_vanilla.sh first"; exit 2; }
done
[ -x "$GWBIN" ] || { echo "build the gateway first: gateway/build.sh"; exit 2; }
rc=0
step() { echo; echo "=== $*"; }
reset_world() { tools/pg-dev.sh psql -tAc "select mc.reset_dev_world(6)" > /dev/null; }

if [ "${1:-}" != "--no-setup" ]; then
  step "build the server database"
  tests/gateway/setup_db.sh > "$OUT/setup.log" 2>&1 || { tail -5 "$OUT/setup.log"; exit 1; }
fi
PSQL="psql -X -q -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft"

DBCRAFT_GW_DATABASE_URL="host=/tmp port=$DBCRAFT_PGPORT user=postgres dbname=dbcraft" DBCRAFT_GW_LISTEN="127.0.0.1:$PORT" \
  DBCRAFT_GW_MAX_CONNECTIONS_PER_IP=0 DBCRAFT_GW_NEW_CONNECTIONS_PER_IP_PER_SEC=0 DBCRAFT_GW_LOGIN_ATTEMPTS_PER_IP_PER_MIN=0 \
  "$GWBIN" > "$OUT/gateway.log" 2>&1 &
GWPID=$!
trap 'kill -TERM $GWPID 2>/dev/null; wait $GWPID 2>/dev/null' EXIT
for i in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); s.connect(('127.0.0.1',$PORT))" 2>/dev/null && break
  sleep 0.2
done

step "join: a returning player (login, configuration, entry burst, chunks)"
reset_world
python3 tools/capture_vanilla.py --port $PORT --seconds 3 --name Probe --out "$OUT/ours_join_first.jsonl" > /dev/null
python3 tools/capture_vanilla.py --port $PORT --seconds 3 --name Probe --out "$OUT/ours_join.jsonl" > /dev/null
python3 tests/e2e/compare_join.py "$VAN/vanilla_join_returning.jsonl" "$OUT/ours_join.jsonl" || rc=1

step "block changes: break, place, break again, seen by the actor and an observer"
reset_world
python3 tests/e2e/block_probe.py --port $PORT --out "$OUT/ours_block" --actor Acta --observer Bert > /dev/null 2>&1
python3 tests/e2e/compare_block.py "$VAN/vanilla_block" "$OUT/ours_block" || rc=1

step "chunk streaming while walking across chunk borders"
reset_world
python3 tests/e2e/move_probe.py --port $PORT --name Walker --steps 6 --out "$OUT/ours_move" > /dev/null 2>&1
python3 tests/e2e/compare_move.py "$VAN/vanilla_move6.jsonl" "$OUT/ours_move.jsonl" || rc=1

step "two players: join, chat, leave"
reset_world
python3 tests/e2e/join_probe.py --port $PORT --out "$OUT/ours_social" --first Opa --second Bobb > /dev/null 2>&1
python3 tests/e2e/compare_social.py "$VAN/vanilla_social" "$OUT/ours_social" || rc=1

step "gateway statistics (net.gateway_stats, last rows)"
$PSQL -c "select 'ticks=' || ticks, 'late=' || late_ticks, 'tick_ms_avg=' || round(tick_ms_avg::numeric, 2), 'tick_ms_max=' || round(tick_ms_max::numeric, 2), 'frames_in=' || frames_in, 'bytes_out=' || bytes_out, 'conns=' || connections, 'errors=' || errors from net.gateway_stats order by ts desc limit 3"
step "no connection rows left behind"
echo "net.conn rows: $($PSQL -c 'select count(*) from net.conn')"

kill -TERM $GWPID 2>/dev/null; wait $GWPID 2>/dev/null
trap - EXIT
echo
[ $rc = 0 ] && echo "ALL END-TO-END COMPARISONS PASSED (Rust gateway)" || echo "SOME END-TO-END COMPARISONS FAILED (Rust gateway)"
exit $rc
