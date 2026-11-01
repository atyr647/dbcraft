#!/usr/bin/env bash
# Several generator loops draining one request queue (mc.chunk_request, FOR UPDATE SKIP LOCKED): is every chunk made exactly once, and what does it buy?
#   tests/bench/world/parallel_generate.sh [DATABASE] [CHUNKS] [MAX_WORKERS]      (psql settings from PGHOST/PGPORT/PGUSER)
# Each round queues CHUNKS pregeneration requests in a fresh region and lets N psql sessions run mc.generate_pending in a loop until the queue is empty.
set -euo pipefail
DB=${1:-dbcraft}; CHUNKS=${2:-3000}; MAXW=${3:-4}
P="psql -X -q -v ON_ERROR_STOP=1 -d $DB"
base=$(( 100000 + RANDOM * 20 ))
$P -c "select mc.generate_flat('minecraft:overworld', $base - 1, 0)" >/dev/null     # builds the template once, outside the timing
for w in $(seq 1 "$MAXW"); do
  region=$(( base + w * 10000 ))
  $P -c "truncate mc.chunk_request, mc.chunk_wanted" \
     -c "insert into mc.chunk_request (dimension, cx, cz, prio, pregen) select 'minecraft:overworld', $region + g, 0, g, true from generate_series(0, $CHUNKS - 1) g"
  start=$(date +%s.%N)
  for i in $(seq 1 "$w"); do
    $P -c "do \$\$ declare n int; begin loop n := mc.generate_pending(32); commit; exit when n = 0; end loop; end \$\$" &
  done
  wait
  end=$(date +%s.%N)
  made=$($P -tA -c "select count(*) from mc.chunk where dimension = 'minecraft:overworld' and cx between $region and $region + $CHUNKS - 1 and cz = 0")
  left=$($P -tA -c "select count(*) from mc.chunk_request")
  cached=$($P -tA -c "select count(*) from mc.chunk_cache where dimension = 'minecraft:overworld' and cx between $region and $region + $CHUNKS - 1 and cz = 0")
  sections=$($P -tA -c "select count(*) from mc.chunk_section where dimension = 'minecraft:overworld' and cx between $region and $region + $CHUNKS - 1 and cz = 0")
  python3 - "$w" "$CHUNKS" "$made" "$left" "$cached" "$sections" "$start" "$end" <<'PY'
import sys
w, want, made, left, cached, sections, t0, t1 = sys.argv[1:]
dt = float(t1) - float(t0)
ok = int(made) == int(want) and int(left) == 0 and int(cached) == int(want) and int(sections) == int(want)
print(f"{w} generator loop(s): {made}/{want} chunks, {left} requests left, {cached} cached packets, {sections} sections: {dt:5.2f} s = {int(want)/dt:7.0f} chunks/s  {'OK exactly once' if ok else 'MISMATCH'}")
sys.exit(0 if ok else 1)
PY
done
uptime
