#!/usr/bin/env bash
# usage: sock_run.sh select|epoll NCONN [CLIENT_PROCS] [DUR]   (loopback; clients = tests/bench/tcl/sock_client.py, closed loop)
set -u; HERE=$(cd "$(dirname "$0")" && pwd); KIND=$1; N=$2; CP=${3:-1}; DUR=${4:-8}
ulimit -n 20000 2>/dev/null || true
PORT=$((26000 + RANDOM % 3000))
PORT=$PORT NCONN=$N DUR=$DUR "$HERE/bin/sock_$KIND" > "$HERE/out_sock_$KIND.$N.log" 2>&1 &
SP=$!; sleep 1
PER=$(( (N + CP - 1) / CP ))
for i in $(seq 1 "$CP"); do PORT=$PORT NCONN=$PER python3 "$HERE/../tcl/sock_client.py" > /dev/null 2>&1 & done
wait $SP 2>/dev/null; sleep 1; pkill -f sock_client.py 2>/dev/null
echo "[$KIND clients=$N client_procs=$CP load=$(cut -d' ' -f1 /proc/loadavg)]"; cat "$HERE/out_sock_$KIND.$N.log" | tail -3
