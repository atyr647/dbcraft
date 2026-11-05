#!/usr/bin/env bash
# The visibility refresh on its own, on the state a walk.sh run left behind: a fraction of the players is moved STEP blocks along its heading (so it becomes dirty), the function is timed
# (wall clock inside the database, in a subtransaction that is rolled back), REPS times.   usage: DBCRAFT_TESTDB=... tests/bench/game/vis_micro.sh FUNCTION [FRAC] [STEP] [REPS]
#   e.g.  tests/bench/game/vis_micro.sh mc.refresh_visibility_vis 0.27 4.6 10        (27 % of 500 players dirty = a tick of walkers at 1.1 blocks per tick)
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_TESTDB:-dbcraft_game}
exec psql -X -At -v fn="$1" -v frac="${2:-0.27}" -v step="${3:-4.6}" -v reps="${4:-10}" -f tests/bench/game/vis_micro.sql
