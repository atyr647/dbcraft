#!/usr/bin/env bash
# usage: pgb_scale.sh ROUNDS SECONDS [workloads...]    (cluster from PGHOST/PGPORT/PGUSER, database pgb; run pgb_setup.sql first)
# For N = 1..4 clients and each workload one pgbench run of SECONDS, ROUNDS times.  Prints tps; efficiency = tps(N) / tps(1) / N.
# workloads: cpu compute upd_log upd_unl queue tick tick_shared
set -euo pipefail
DIR="$(dirname "$0")"
ROUNDS=${1:-2}; SECS=${2:-8}; shift 2 || true
WL=${*:-cpu compute upd_log upd_unl queue tick tick_shared}
for r in $(seq 1 "$ROUNDS"); do
  for w in $WL; do
    for n in 1 2 3 4; do
      l=$(cut -d' ' -f1 /proc/loadavg)
      out=$(pgbench -n -c "$n" -j "$n" -T "$SECS" -f "$DIR/pgb_$w.sql" pgb 2>&1 | awk '/^tps/ {print $3}')
      echo "round=$r workload=$w clients=$n tps=$out load_before=$l psi=$(awk '/some/ {print $2}' /proc/pressure/cpu)"
      sleep 2
    done
  done
done
