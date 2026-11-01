#!/usr/bin/env bash
# PGO training run: the instrumented build (variant D1, cluster G) executes the representative workload mix, then is stopped CLEANLY so every backend
# and the postmaster write their profile data (.gcda files in /tmp/pgbuild/pgo-data).   usage: tools/pgbuild/train.sh
# Training mix (what dbcraft's server spends its CPU on):
#   * the whole server tick: 500 players all moving (150 ticks), 500 players 20% moving (100 ticks), 2,000 players view distance 5 (60 ticks)
#   * the chunk join path: 441 cached chunk packet bodies x 40
#   * block edits: mc.set_block x 20,000 at random positions
#   * world generation: mc.generate_batch of 64 chunks x 12
set -euo pipefail
cd "$(dirname "$0")/../.."
tools/pgbuild/cluster.sh G start
eval "$(tools/pgbuild/cluster.sh G env)"
export DBCRAFT_BENCH_DB=dbcraft
VIEW=10 tests/bench/tick/run.sh 500 100 1.0 150 train_all  | head -1
VIEW=10 tests/bench/tick/run.sh 500 100 0.2 100 train_20   | head -1
VIEW=5  tests/bench/tick/run.sh 2000 160 1.0 60 train_2000 | head -1
psql -X -q -At -c "select rt.join441(40)"
psql -X -q -At -c "select rt.setblock(20000)"
for i in $(seq 1 12); do psql -X -q -At -c "select rt.gen64()" > /dev/null; done
tools/pgbuild/cluster.sh G stop
echo "profile files: $(ls /tmp/pgbuild/pgo-data | wc -l), $(du -sh /tmp/pgbuild/pgo-data | cut -f1)"
