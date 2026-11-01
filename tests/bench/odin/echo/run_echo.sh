#!/usr/bin/env bash
# usage: run_echo.sh CONNS [TICKS=200]   - Odin nbio echo server vs the Python load generator from tests/prototype (5 frames of 31 B per 50 ms tick per connection)
set -e; HERE=$(cd "$(dirname "$0")" && pwd); N=${1:-5000}; T=${2:-200}; PORT=$((26000 + RANDOM % 2000))
export ODIN_ROOT=${ODIN_ROOT:-/tmp/odin-dl/odin-src}; ulimit -n 20000
[ -x "$HERE/echo_bin" ] || ( cd "$HERE" && "$ODIN_ROOT/odin" build . -file -o:speed -out:echo_bin )
echo "load before: $(uptime | sed 's/.*load average/load average/')"
"$HERE/echo_bin" "$PORT" $((T / 20 + 4)) > "$HERE/server.out" 2> "$HERE/server.err" &
SPID=$!
sleep 1
python3 "$HERE/../../../prototype/pl_gateway_load.py" "$N" "$PORT" "$T" 5
wait $SPID || true
cat "$HERE/server.out" "$HERE/server.err"
echo "server cpu (utime+stime ticks from /proc, sampled at exit is unavailable): see 'times' below"; times
