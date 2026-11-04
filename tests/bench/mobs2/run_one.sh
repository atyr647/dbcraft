#!/usr/bin/env bash
# usage: tests/bench/mobs2/run_one.sh CODE REP LABEL OUT [extra psql -v args]      CODE as in tools/entity/vanilla_mobs.py:  500v 2000v 5000v 2000n 5000n 5000i 0
# One dbcraft measurement of the same scenario (tests/bench/mobs2/bench.sql: 100 measured entity ticks after 30 warm-up ticks), appended to OUT as one line "rep REP | result".
# env: PGHOST PGPORT PGUSER PGDATABASE (the cluster of tests/bench/entity/setup_db.sh), PGOPTIONS (e.g. '-c dbcraft.entity_lanes=off')
set -euo pipefail
cd "$(dirname "$0")/../../.."
code=$1; rep=$2; label=$3; out=$4; shift 4
n=${code%[vnia]}; k=${code#$n}
mobs=$n; items=0; where=view
case "$k" in n) where=ring;; i) mobs=0; items=$n;; esac
[ "$n" = 0 ] && { mobs=0; items=0; }
line=$(psql -X -q -At -v ON_ERROR_STOP=1 -v mobs=$mobs -v items=$items -v where=$where -v ticks=${TICKS:-100} -v label="$label/$code" "$@" -f tests/bench/mobs2/bench.sql | tail -1)
echo "rep $rep | $line" | tee -a "$out"
