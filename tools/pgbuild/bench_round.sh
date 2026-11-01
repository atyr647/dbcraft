#!/usr/bin/env bash
# One round of every workload against one variant's cluster; raw result lines are appended to OUT:  ROUND VARIANT WORKLOAD ... (parsed by analyze.py)
#   usage: tools/pgbuild/bench_round.sh VARIANT ROUND OUTFILE
# Workloads (all report backend ON-CPU time from /proc/self/schedstat; tick numbers are per tick, 20 warm-up ticks dropped):
#   t500_all   500 players, 100x100 chunks, all moving, view distance 10
#   t500_20    the same with 20% moving
#   t2000      2,000 players over 160x160 chunks, all moving, view distance 5
#   join441    441 cached chunk packet bodies (ms per batch)
#   setblock   mc.set_block (us per call)
#   gen64      mc.generate_batch of 64 chunks (ms per batch)
set -euo pipefail
cd "$(dirname "$0")/../.."
V=$1; R=$2; OUT=$3
eval "$(tools/pgbuild/cluster.sh "$V" env)"
export DBCRAFT_BENCH_DB=dbcraft
TICKS=${TICKS:-80}
LOAD=$(cut -d' ' -f1 /proc/loadavg)
tick() {  # label players side frac view
  line=$(VIEW=$5 tests/bench/tick/run.sh "$2" "$3" "$4" "$TICKS" "$1" | head -1)
  echo "$R $V $1 load=$LOAD $line" >> "$OUT"
}
micro() {  # label sql
  val=$(psql -X -q -At -c "$2")
  echo "$R $V $1 load=$LOAD value=$val" >> "$OUT"
}
tick t500_all  500  100 1.0 10
tick t500_20   500  100 0.2 10
tick t2000     2000 160 1.0 5
micro join441  "select rt.join441(10)"
micro setblock "select rt.setblock(3000)"
micro gen64    "select rt.gen64()"
