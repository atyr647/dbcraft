#!/usr/bin/env bash
# In-database profile of the locator bar with directional walkers (tests/bench/game/walk.sh) reporting CPU time of the tick, not wall time.
# usage: tests/bench/game/walk_prof.sh PLAYERS TICKS LABEL [BAR_CAP] [SIDE_CHUNKS] [SPEED] [FUNCS=0|1] [COUNT=0|1]
#   BAR_CAP   value of dbcraft.locator-bar-max-players for the run: 0 = bar off, a large number = bar on at any player count (default 100000)
#   FUNCS=1   also prints pg_stat_user_functions (track_functions = all: PL/pgSQL functions only; the run is slower)
#   COUNT=1   counts the waypoint packets of every tick (a PL/pgSQL decoder between tick and drain: not part of the CPU figure)
# Needs a migrated database in DBCRAFT_TESTDB (default dbcraft_game), like walk.sh.  The first 20 ticks are warm-up.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:?players}; T=${2:-60}; L=${3:-run}; CAP=${4:-100000}; SIDE=${5:-30}; SP=${6:-0.215}; FUNCS=${7:-0}; COUNT=${8:-0}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_TESTDB:-dbcraft_game}
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/game/bench.sql -f tests/bench/game/walk.sql -f tests/bench/game/walk_prof.sql > /dev/null 2>&1
$P -c "truncate bench.step, bench.cpu, bench.wpn" -c "select bench.setup($N, $SIDE)" -c "update mc.server_property set value = '$CAP' where key = 'dbcraft.locator-bar-max-players'" -c "delete from mc.wp" -c "select pg_stat_reset()" > /dev/null
$P -c "select count(*) from mc.refresh_visibility()" > /dev/null
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
if [ "$FUNCS" = 1 ]; then echo "set track_functions = 'all';" > "$SCRIPT"; fi
for i in $(seq 1 "$T"); do
  printf 'select bench.gen_walk(%s, %s);\nselect bench.cpu_ns() as c0 \\gset\nselect mc.tick();\nselect bench.cpu_ns() - :c0 as dc \\gset\n' "$SP" "$SIDE"
  if [ "$COUNT" = 1 ]; then printf 'select bench.count_wp();\n'; fi
  printf 'select bench.drain();\ninsert into bench.cpu select game_time, :dc from mc.game_state;\n'
done >> "$SCRIPT"
$P -o /dev/null -f "$SCRIPT"
$P -c "select line from bench.cpu_summary('$L players=$N side=$SIDE cap=$CAP speed=$SP')"
$P -c "select 'wp rows ' || count(*) || ' (block ' || count(*) filter (where kind = 1) || ' chunk ' || count(*) filter (where kind = 2) || ' azimuth ' || count(*) filter (where kind = 3) || ')' from mc.wp"
if [ "$FUNCS" = 1 ]; then
  sleep 1.5
  $P -c "select format('%-34s calls/tick %7s  ms/tick %8s  self ms/tick %8s', schemaname || '.' || funcname, round(calls::numeric / $T, 1), round((total_time / $T)::numeric, 3), round((self_time / $T)::numeric, 3)) from pg_stat_user_functions where funcname ~ 'wp|vis_|refresh_vis' order by total_time desc limit 14"
fi
