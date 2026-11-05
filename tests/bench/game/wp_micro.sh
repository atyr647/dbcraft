#!/usr/bin/env bash
# The locator bar pass alone, reference (every pair) against dirty-driven, alternately on the same state: wall ms of the pass.
# usage: tests/bench/game/wp_micro.sh PLAYERS [ITERATIONS] [SIDE_CHUNKS] [SPEED]
# Wall time is noisy on a shared machine; the alternation and the median/p10 make the ratio meaningful.  Needs a migrated database in DBCRAFT_TESTDB (default dbcraft_game).
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:?players}; IT=${2:-40}; SIDE=${3:-30}; SP=${4:-0.215}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_TESTDB:-dbcraft_game}
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/game/bench.sql -f tests/bench/game/walk.sql -f tests/bench/game/wp_micro.sql > /dev/null 2>&1
$P -c "truncate bench.step" -c "select bench.setup($N, $SIDE)" -c "update mc.server_property set value = '100000' where key = 'dbcraft.locator-bar-max-players'" -c "delete from mc.wp" > /dev/null
$P -c "select count(*) from mc.refresh_visibility()" > /dev/null
$P -c "select line from bench.wp_micro($IT, $SP)"
