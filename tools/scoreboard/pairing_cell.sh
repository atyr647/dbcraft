#!/usr/bin/env bash
# One short storm2 cell of docs/PERF-PAIRING.md: N joins (default 200) into 20 online players, own cluster (CAP_DIR / CAP_PORT), results appended to docs/perf-pairing-results.txt.
#   usage: CAP_DIR=/dev/shm/pp_cap CAP_PORT=56830 tools/scoreboard/pairing_cell.sh TAG [N] [extra run.py args]
set -uo pipefail
cd "$(dirname "$0")/.."/..
TAG=$1; N=${2:-200}; shift; shift || true
CAP_DIR=${CAP_DIR:-/dev/shm/pp_cap} CAP_PORT=${CAP_PORT:-56830} SCORE_RESULTS=$PWD/docs/perf-pairing-results.txt \
  tools/scoreboard/cenv_capacity python3 tools/scoreboard/run.py storm2 --n "$N" --reps 1 --servers dbcraft --tag "$TAG" --load-max 3.5 --load-wait 240 --quiet-wait 0 "$@"
