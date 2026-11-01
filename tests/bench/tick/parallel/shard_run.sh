#!/usr/bin/env bash
# usage: tests/bench/tick/parallel/shard_run.sh PLAYERS [SECONDS] [ROUNDS]     env: DBCRAFT_PGPORT (54411), SHARD_DB (dbcraft_shard)
# Sharded movement (sql/434) with 1, 2 and 4 concurrent workers, each doing its 1/n of the players per iteration.  An iteration of every worker runs at the same
# time as the others', so the time of one tick is the time of one iteration: ticks/s = (all workers' iterations/s) / n.  Prints ms per tick and the speed-up over
# one worker; the pure-CPU reference (cpu_only.sql on the database pgb) is measured next to every case because other jobs share the machine.
set -euo pipefail
cd "$(dirname "$0")"
N=${1:-500}; SECS=${2:-6}; ROUNDS=${3:-3}; DB=${SHARD_DB:-dbcraft_shard}
PGB=/usr/lib/postgresql/16/bin/pgbench
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54411} PGUSER=postgres PGOPTIONS="-c client_min_messages=warning"
psql -X -q -At -d "$DB" -v ON_ERROR_STOP=1 -f ../../integration/bench.sql -f shard_setup.sql > /dev/null 2>&1
psql -X -q -At -d "$DB" -v ON_ERROR_STOP=1 -c "select ibench.setup($N, 100)" -c "select count(*) from mc.refresh_visibility()" -c "vacuum (analyze) mc.player, mc.visible, net.conn" > /dev/null
printf 'select par2.iter(0, 1);\n' > /tmp/shard_n1.sql
printf 'select par2.iter(:client_id, 2);\n' > /tmp/shard_n2.sql
printf 'select par2.iter(:client_id, 4);\n' > /tmp/shard_n4.sql
ref() { $PGB -n -c "$1" -j "$1" -T 3 -f cpu_only.sql pgb 2>&1 | awk '/^tps =/ {print $3}'; }
run() { psql -X -q -At -d "$DB" -c "truncate mc.play_out, mc.play_in_work" > /dev/null; $PGB -n -c "$1" -j "$1" -T "$SECS" -f "/tmp/shard_n$1.sql" "$DB" 2>&1 | awk '/^tps =/ {print $3}'; }
printf 'players %s; load average at start %s\n' "$N" "$(cut -d' ' -f1 /proc/loadavg)"
printf '%8s %12s %12s %12s   %s\n' workers "ms per tick" "speed-up" "reference" "efficiency"
for r in $(seq 1 "$ROUNDS"); do
  r1=$(ref 1); t1=$(run 1); base_ms=$(echo "1000 / $t1" | bc -l)
  for w in 1 2 4; do
    if [ "$w" != 1 ]; then rw=$(ref "$w"); tw=$(run "$w"); else rw=$r1; tw=$t1; fi
    ms=$(echo "1000 / ($tw / $w)" | bc -l); sp=$(echo "$base_ms / $ms" | bc -l); rs=$(echo "$rw / $r1" | bc -l)
    printf '%8d %12.1f %12.2f %12.2f   %.2f\n' "$w" "$ms" "$sp" "$rs" "$(echo "$sp / $rs" | bc -l)"
  done
done
