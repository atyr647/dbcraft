#!/usr/bin/env bash
# Directional walkers for the in-database bench (tests/bench/game/bench.sql only jitters players by +-0.2 blocks, which hides the cost of a crowd: nobody travels).
# usage: tests/bench/game/walk.sh SPEED_BLOCKS_PER_TICK TICKS LABEL [PLAYERS] [SIDE_CHUNKS]     e.g. walk.sh 0.215 70 crowd 500 30
# 0.215 blocks per tick is a walking player at a true 20 Hz (4.3 blocks/s); a tick of 250 ms means 1.1 blocks per tick, so a slow tick feeds its own cost (docs/perf-crowd-live-profile-2026-11-05.txt).
# Needs a migrated database in DBCRAFT_TESTDB (default dbcraft_game) like tests/bench/game/run.sh.  Only mc.tick() is measured: no gateway, no net.stream_chunks.
set -euo pipefail
cd "$(dirname "$0")/../../.."
SP=${1:?speed}; T=${2:-70}; L=${3:-walk}; N=${4:-500}; SIDE=${5:-30}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_TESTDB:-dbcraft_game}
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/game/bench.sql -f tests/bench/game/walk.sql > /dev/null 2>&1
$P -c "truncate bench.step" -c "select bench.setup($N, $SIDE)" > /dev/null
$P -c "select count(*) from mc.refresh_visibility()" > /dev/null
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
for i in $(seq 1 "$T"); do printf 'select bench.gen_walk(%s, %s);\nselect mc.tick();\nselect bench.drain();\n' "$SP" "$SIDE"; done > "$SCRIPT"
$P -o /dev/null -f "$SCRIPT"
$P -c "select line from bench.summary('$L speed=$SP/tick')"
