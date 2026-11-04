#!/usr/bin/env bash
# Alternating real-harness A/B of the capacity work (docs/PERF-CAPACITY.md): the tree before it (BASE_TREE, its own cluster CAP_DIR_A / CAP_PORT_A, its own gateway binary) against this tree
# (CAP_DIR_B / CAP_PORT_B), one scenario per call, REPS repetitions, A then B each time, one result line per run in OUT.  Both use tools/scoreboard/run.py (CPU time of the tick backend
# and of the gateway per tick, tick wall time, clients dropped).
#   usage: tools/scoreboard/cap_ab.sh REPS OUT -- run.py SCENARIO ARGS...        e.g.  tools/scoreboard/cap_ab.sh 3 /dev/shm/cap/ab200.txt -- pop --n 200 --moving 1.0 --bound 500 --hold 60
set -u
BASE_TREE=${BASE_TREE:-$(cd "$(dirname "$0")/../.." && pwd)/.capbase}
CAP_DIR_A=${CAP_DIR_A:-/dev/shm/cap2}; CAP_PORT_A=${CAP_PORT_A:-56221}
CAP_DIR_B=${CAP_DIR_B:-/dev/shm/cap};  CAP_PORT_B=${CAP_PORT_B:-56211}
REPS=$1; OUT=$2; shift 3
cd "$(dirname "$0")/../.."
for r in $(seq 1 "$REPS"); do
  CAP_DIR=$CAP_DIR_A CAP_PORT=$CAP_PORT_A "$BASE_TREE/tools/scoreboard/cenv_capacity" python3 "$BASE_TREE/tools/scoreboard/run.py" "$@" --reps 1 --servers dbcraft --quiet-wait 0 --tag A 2>&1 | tail -1 | sed 's/^/A /' | tee -a "$OUT"
  CAP_DIR=$CAP_DIR_B CAP_PORT=$CAP_PORT_B tools/scoreboard/cenv_capacity python3 tools/scoreboard/run.py "$@" --reps 1 --servers dbcraft --quiet-wait 0 --tag B 2>&1 | tail -1 | sed 's/^/B /' | tee -a "$OUT"
done
