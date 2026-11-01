#!/usr/bin/env bash
# usage: tests/bench/tick/parallel/run.sh [SECONDS] [ROUNDS]      env: DBCRAFT_PGPORT (54411)
# Scaling of concurrent writers.  Each pgbench client runs one statement; the cases are
#   cpu_only   a query that touches no table and writes nothing (the reference: how much parallelism the machine gives right now)
#   sep_pw     500 wide rows updated in its OWN logged table      sep_pu     the same, unlogged
#   shared_pw  500 wide rows (own block) in one shared logged table   shared_pu  the same, unlogged
# at 1 and 4 clients.  Other jobs share this machine, so the raw speed-up of 4 clients says little; the cpu_only run is repeated right before every case and the
# last column is the case's speed-up divided by the reference's (1.00 = scales as well as pure CPU does at that moment).  Needs setup.sql + funcs.sql (database pgb).
set -euo pipefail
cd "$(dirname "$0")"
SECS=${1:-5}; ROUNDS=${2:-3}
PGB=/usr/lib/postgresql/16/bin/pgbench
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres
tps() { $PGB -n -c "$1" -j "$1" -T "$SECS" -f "$2.sql" pgb 2>&1 | awk '/^tps =/ {print $3}'; }
printf 'load average at start %s\n' "$(cut -d' ' -f1 /proc/loadavg)"
printf '%-10s %9s %9s %9s %9s   %s\n' case "1 client" "4 clients" "speed-up" "reference" "efficiency (speed-up / reference)"
for sc in sep_pw sep_pu shared_pw shared_pu; do
  for r in $(seq 1 "$ROUNDS"); do
    c1=$(tps 1 cpu_only); c4=$(tps 4 cpu_only)
    a1=$(tps 1 "$sc"); a4=$(tps 4 "$sc")
    printf '%-10s %9.0f %9.0f %9.2f %9.2f   %.2f\n' "$sc" "$a1" "$a4" "$(echo "$a4 / $a1" | bc -l)" "$(echo "$c4 / $c1" | bc -l)" "$(echo "($a4 / $a1) / ($c4 / $c1)" | bc -l)"
  done
done
