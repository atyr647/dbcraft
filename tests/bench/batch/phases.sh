#!/usr/bin/env bash
# Per-phase breakdown (wall ms per tick, from mc.tick_log and mc.server_tick_log) of base and batched for one scenario.
#   usage: tests/bench/batch/phases.sh PLAYERS SIDE FRAC MODE [TICKS]      e.g.  phases.sh 2000 100 1.0 dither 50
# Runs each implementation once (ab.sh with one round), reads the logs the ticks wrote (the last 40 ticks), prints one line per implementation.
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=$1; SIDE=$2; FRAC=$3; MODE=$4; TICKS=${5:-60}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54422} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbbench}
for impl in base batched:all; do
  tests/bench/batch/ab.sh "$impl" "$N" "$SIDE" "$FRAC" "$MODE" split "$TICKS" 1 > /dev/null 2>&1
  psql -X -q -At -F' ' -c "
    select '$impl', 'players=$N side=$SIDE moving=$FRAC',
           'process', round(avg(s.ms_process)::numeric, 1), 'game', round(avg(s.ms_game)::numeric, 1),
           '[moves', round(avg(g.ms_moves)::numeric, 1), 'misc', round(avg(g.ms_misc)::numeric, 1), 'chat', round(avg(g.ms_chat)::numeric, 1), 'visibility', round(avg(g.ms_visibility)::numeric, 1),
           'keepalive', round(avg(g.ms_keepalive)::numeric, 1) || ']', 'blocks', round(avg(s.ms_blocks)::numeric, 1), 'chunks', round(avg(s.ms_chunks)::numeric, 1),
           'drain', round(avg(s.ms_drain)::numeric, 1), 'total', round(avg(s.ms_total)::numeric, 1),
           'viewer pairs', (select count(*) from mc.visible), 'play_out rows/tick', round(avg(s.frames_out)::numeric)
      from mc.server_tick_log s join mc.tick_log g using (tick) where s.tick > 20"
done
