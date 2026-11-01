#!/usr/bin/env bash
# One tuning trial: copy the golden data directory, start a fresh cluster with the given configuration, run the steady-state tick loop at 20 Hz, analyse.
#
# usage: tests/bench/tuning/run.sh NAME [CONF[,CONF...]] [PLAYERS=300] [MOVING_FRACTION=1.0] [SECONDS=180]
#   CONF   file(s) from tests/bench/tuning/conf/ (name without .conf), applied in order after base.conf (logging only); empty = PostgreSQL defaults
#   env    GOLD (default /tmp/dbcraft-pg-tune-gold, from prepare.sh)   TRIAL_DATA (default /tmp/dbcraft-pg-tune-run)   TRIAL_PORT (default 54472)
#          DIAG=1 adds conf/diag.conf (pg_stat_statements, auto_explain, io timing); KEEP=1 keeps the data directory; WARM=ticks of warm-up (default 100)
# Output: tests/bench/tuning/results/NAME/ (gitignored): lat.csv (one row per tick), pg.log, snap_before.json, snap_after.json, summary.json; one summary line on stdout.
set -euo pipefail
cd "$(dirname "$0")/../../.."
NAME=$1; CONFS=${2:-}; N=${3:-300}; FRAC=${4:-1.0}; SECS=${5:-180}
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${TRIAL_DATA:-/tmp/dbcraft-pg-tune-run}; PORT=${TRIAL_PORT:-54472}
WARM=${WARM:-100}
OUT=tests/bench/tuning/results/$NAME
CONFDIR=$PWD/tests/bench/tuning/conf
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
mkdir -p "$OUT"; rm -f "$OUT"/*

as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"
cp -a "$GOLD" "$DATA"
{
  echo "include '$CONFDIR/base.conf'"
  IFS=, read -ra LIST <<< "$CONFS"
  for c in "${LIST[@]}"; do [ -n "$c" ] && echo "include '$CONFDIR/$c.conf'"; done
  if [ "${DIAG:-0}" = 1 ]; then echo "include '$CONFDIR/diag.conf'"; fi
} >> "$DATA/postgresql.conf"
: > "$DATA/log"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null

export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
P="psql -X -q -At -v ON_ERROR_STOP=1"
if [ "${DIAG:-0}" = 1 ]; then $P -c "create extension if not exists pg_stat_statements" >/dev/null; fi
$P -f tests/bench/integration/bench.sql -f tests/bench/tuning/steady.sql >/dev/null 2>&1
$P -c "select ibench.setup($N, 100)" >/dev/null
$P -c "select mc.refresh_visibility()" >/dev/null
$P -c "analyze" -c "checkpoint" >/dev/null     # whole database: ibench.setup bulk-loaded net.conn/mc.player, stale statistics would flip plans (see docs/TUNING.md)
LOAD0=$(cut -d' ' -f1 /proc/loadavg)
$P -c "call tune.run($WARM, 20, $FRAC, $WARM)" >/dev/null
$P -c "select pg_stat_reset_shared('bgwriter')" -c "select pg_stat_reset_shared('wal')" >/dev/null 2>&1 || true
$P -c "select tune.snapshot()" > "$OUT/snap_before.json"
T0=$(date +%s)
$P -c "call tune.run($((SECS * 20)), 20, $FRAC, 0)" >/dev/null
WALL=$(( $(date +%s) - T0 ))
sleep 1
$P -c "select tune.snapshot()" > "$OUT/snap_after.json"
LOAD1=$(cut -d' ' -f1 /proc/loadavg)
$P -c "\copy (select l.seq, l.cur_tick, l.t_start, l.gen_ms, l.tick_ms, l.drain_ms, l.commit_ms, l.lat_ms, l.late_ms, s.ms_process, s.ms_game, s.ms_blocks, s.ms_chunks, s.ms_drain, s.frames_in, s.frames_out from tune.lat l left join mc.server_tick_log s on s.tick = l.cur_tick order by l.seq) to '$OUT/lat.csv' csv header" >/dev/null
if [ "${DIAG:-0}" = 1 ]; then
  $P -c "\copy (select calls, round(total_exec_time::numeric,1) total_ms, round(mean_exec_time::numeric,3) mean_ms, round(max_exec_time::numeric,1) max_ms, rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, wal_bytes, left(regexp_replace(query, '\s+', ' ', 'g'), 160) query from pg_stat_statements order by total_exec_time desc limit 40) to '$OUT/statements.csv' csv header" >/dev/null || true
fi
cp "$DATA/log" "$OUT/pg.log"
as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true
if [ "${KEEP:-0}" != 1 ]; then rm -rf "$DATA"; fi
python3 tests/bench/tuning/analyze.py "$OUT" --name "$NAME" --confs "$CONFS" --players "$N" --frac "$FRAC" --seconds "$SECS" --wall "$WALL" --load "$LOAD0,$LOAD1"
