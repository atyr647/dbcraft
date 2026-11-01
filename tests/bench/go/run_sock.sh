#!/usr/bin/env bash
# Socket + GC scenarios.  usage: run_sock.sh NCONN [ENV=VAL ...]   e.g. run_sock.sh 20000 GOGC=10 HOLD_PTR_MB=1024
# Server and load generator are separate processes on the same machine (4 cores shared), so frames/s is a floor, not a ceiling.
set -euo pipefail
cd "$(dirname "$0")"
ulimit -n 20000  # hard limit in this container; so the "20k" scenario below uses 19000 connections (listener, epoll and stdio need descriptors too)
N=$1; shift
PORT=$((25700 + RANDOM % 200))
echo "== NCONN=$N PACE_MS=${PACE_MS:-0} server_cpus=${SERVER_CPUS:-0,1} $* | $(uptime | sed 's/.*load/load/')"
env PORT=$PORT NCONN=$N DUR=${DUR:-15} GOMAXPROCS=${SERVER_PROCS:-2} "$@" taskset -c ${SERVER_CPUS:-0,1} bin/sockserver > out/sock.$$.log &
SP=$!
sleep 0.5
PORT=$PORT NCONN=$N PACE_MS=${PACE_MS:-0} taskset -c ${CLIENT_CPUS:-2,3} bin/sockclient > out/sockclient.$$.log &
CP=$!
wait $SP || true
kill $CP 2>/dev/null || true; wait $CP 2>/dev/null || true
cat out/sock.$$.log
