#!/usr/bin/env bash
# Gateway-shaped socket test: ./run_sockets.sh NOTIFIER(select|epoll) NCONN [DUR=10] [PORT]
set -u
HERE=$(cd "$(dirname "$0")" && pwd); OUT=$HERE/../out
N=$2; DUR=${3:-10}; PORT=${4:-$((26000 + RANDOM % 3000))}
export TCL_LIBRARY=${TCL_LIBRARY:-/home/user/atyr647/tcl-aot/build/tcl8.6.14/library}
ulimit -n 20000 2>/dev/null || true
[ "$1" = epoll ] && export DBC_NOTIFIER=epoll
PORT=$PORT NEXP=$N DUR=$DUR "$OUT/dbcshell" "$HERE/gwserver.tcl" > "$OUT/srv.$1.$N.log" 2>&1 &
SP=$!
sleep 1
"$OUT/loadgen" $PORT $N 20 $((DUR + 4)) > "$OUT/lg.$1.$N.log" 2>&1
wait $SP; echo "[$1 N=$N] $(grep -h LOADGEN $OUT/lg.$1.$N.log | cut -c1-200)"; grep -h -E "SUMMARY|FD_SETSIZE|terminated|error" "$OUT/srv.$1.$N.log" | head -3; grep -h "connected" "$OUT/lg.$1.$N.log" | head -2
