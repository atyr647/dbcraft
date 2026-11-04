#!/usr/bin/env bash
# several scenarios one after the other on a flat reset area: tests/bench/mobs2/quick.sh LABEL CODE...    env: PGHOST PGPORT PGUSER PGDATABASE; OUT=file (default /dev/shm/mob3/quick.txt); EXTRA='-v x=y'
cd "$(dirname "$0")/../../.."
label=$1; shift
for c in "$@"; do
  tests/bench/mobs2/run_one.sh "$c" 1 "$label" "${OUT:-/dev/shm/mob3/quick.txt}" -v warm=${WARM:-150} -v reset=1 ${EXTRA:-} 2>&1 | grep -v NOTICE | cut -c1-270
done
