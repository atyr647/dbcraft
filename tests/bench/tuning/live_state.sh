#!/usr/bin/env bash
# State tiering experiment (docs/TUNING.md, "state tiering"): wide mc.player vs a narrow logged hot table vs a narrow UNLOGGED hot table + durable snapshots.
# Same update pattern for all (tests/bench/tuning/live_state.sql), 20 Hz, one transaction per tick.  Throwaway copy of the golden database, reference configuration.
#
# usage: tests/bench/tuning/live_state.sh [TICKS=1200] [CASES...]       a case is  VARIANT:PLAYERS:MOVING_FRACTION[:SNAPSHOT_EVERY]
#        default cases: wide / hot_logged / hot_unlogged(snapshot every 100 ticks = 5 s) at 500 and 2000 players, all moving and 25% moving, plus a 15 s snapshot
# env    GOLD, LS_DATA (default /tmp/dbcraft-pg-tune-ls), LS_PORT (default 54476)
set -euo pipefail
cd "$(dirname "$0")/../../.."
TICKS=${1:-1200}; shift || true
GOLD=${GOLD:-/tmp/dbcraft-pg-tune-gold}; DATA=${LS_DATA:-/tmp/dbcraft-pg-tune-ls}; PORT=${LS_PORT:-54476}
CASES=("$@")
if [ ${#CASES[@]} -eq 0 ]; then
  CASES=(wide:500:1.0 hot_logged:500:1.0 hot_unlogged:500:1.0:100 hot_unlogged:500:1.0:300
         wide:500:0.25 hot_logged:500:0.25 hot_unlogged:500:0.25:100
         wide:2000:1.0 hot_logged:2000:1.0 hot_unlogged:2000:1.0:100
         wide:2000:0.25 hot_logged:2000:0.25 hot_unlogged:2000:0.25:100)
fi
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; cp -a "$GOLD" "$DATA"
{ echo "include '$PWD/tests/bench/tuning/conf/base.conf'"; echo "include '$PWD/tests/bench/tuning/conf/ref.conf'"; } >> "$DATA/postgresql.conf"
: > "$DATA/log"
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/tuning/live_state.sql >/dev/null
printf '%-34s | %-24s | %-18s | %-20s | %-26s | %s\n' "case (variant:players:moving:snap)" "tick ms avg / p99 / max" "WAL KB/tick (fpi %)" "snapshot ms avg (when run)" "dead tuples / autovac runs" "table sizes; vacuum ms"
for c in "${CASES[@]}"; do
  IFS=: read -r V N F S <<< "$c"; S=${S:-0}
  $P -c "call lv.setup('$V', $N)" >/dev/null
  $P -c "checkpoint" >/dev/null
  $P -c "select pg_stat_reset_shared('wal')" >/dev/null
  $P -c "select pg_stat_reset_single_table_counters('lv.player_wide'::regclass)" >/dev/null
  [ "$V" != wide ] && $P -c "select pg_stat_reset_single_table_counters('lv.player_hot'::regclass)" >/dev/null
  $P -c "call lv.run('$V', $TICKS, $F, $S)" >/dev/null
  sleep 1
  WAL=$($P -F ' ' -c "select round(wal_bytes / 1024.0 / $TICKS, 1), case when wal_records = 0 then 0 else round(100.0 * wal_fpi / wal_records) end from pg_stat_wal")
  LAT=$($P -F ' / ' -c "select round(avg(ms)::numeric, 1), round((percentile_cont(.99) within group (order by ms))::numeric, 1), round(max(ms)::numeric, 1) from lv.lat")
  SNAP=$($P -c "select case when count(*) filter (where snap_ms > 0) = 0 then '-' else round((avg(snap_ms) filter (where snap_ms > 0))::numeric, 1)::text || ' (' || count(*) filter (where snap_ms > 0) || 'x)' end from lv.lat")
  DEAD=$($P -c "select string_agg(relname || ' ' || n_dead_tup || '/' || autovacuum_count, ', ' order by relname) from pg_stat_user_tables where schemaname = 'lv' and relname in ('player_wide', 'player_hot')")
  SZ=$($P -c "select string_agg(relname || ' ' || pg_size_pretty(pg_table_size(relid)), ', ' order by relname) from pg_stat_user_tables where schemaname = 'lv' and relname in ('player_wide', 'player_hot')")
  VT=""
  for t in player_wide player_hot; do
    [ "$t" = player_hot ] && [ "$V" = wide ] && continue
    T0=$(date +%s%N); $P -c "vacuum lv.$t" >/dev/null; VT="$VT $t $(( ($(date +%s%N) - T0) / 1000000 ))"
  done
  printf '%-34s | %-24s | %-18s | %-26s | %-26s | %s;%s\n' "$c" "$LAT" "$WAL" "$SNAP" "$DEAD" "$SZ" "$VT"
done
