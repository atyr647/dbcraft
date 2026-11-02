#!/usr/bin/env bash
# usage: shard_both.sh [ROUNDS]   env: DBCRAFT_PGPORT, SHARD_DB   (the sharded movement prototype, 1-4 workers, 500 and 2,000 players; the machine must be otherwise idle)
set -euo pipefail
DIR="$(dirname "$0")"
ROUNDS=${1:-2}
for n in 500 2000; do
  bash "$DIR/../tick/parallel/shard_run.sh" "$n" 6 "$ROUNDS"
done
