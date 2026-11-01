#!/usr/bin/env bash
# Interleaved A/B of the entity tick: for each round run the benchmark once per variant (variants are PGOPTIONS strings), print one line per run and a median table.
# usage: tests/bench/entity/ab.sh ROUNDS "label1|PGOPTIONS1" "label2|PGOPTIONS2" ... -- bench_tick.sql variables, e.g.  -- -v players=1 -v mobs=2000 -v area=40 -v ticks=60
# The machine is shared with other workers: only the interleaved medians mean anything.  Connection: PG* environment.
set -euo pipefail
cd "$(dirname "$0")/../../.."
rounds=$1; shift
variants=()
while [ "$1" != "--" ]; do variants+=("$1"); shift; done
shift
declare -A tot ai phys trk
for r in $(seq 1 "$rounds"); do
  for v in "${variants[@]}"; do
    label=${v%%|*}; opts=${v#*|}
    out=$(PGOPTIONS="$opts" psql -X -q "$@" -f tests/bench/entity/bench_tick.sql 2>&1)
    t=$(echo "$out" | awk -F'|' '/cpu: whole entity tick/ {gsub(/ /,"",$2); print $2}')
    a=$(echo "$out" | awk -F'|' '/viewers\+ai/ {gsub(/ /,"",$2); print $2}')
    p=$(echo "$out" | awk -F'|' '/ physics/ {gsub(/ /,"",$2); print $2}')
    k=$(echo "$out" | awk -F'|' '/tracker/ {gsub(/ /,"",$2); print $2}')
    w=$(echo "$out" | awk -F'|' '/^ +[0-9]+ +\|/ {gsub(/ /,"",$4); print $4; exit}')
    aw=$(echo "$out" | awk '/avg_entities_processed/ {getline; getline; print $1}')
    echo "round $r  $label: total=$t ai=$a physics=$p tracker=$k  processed/tick=$aw  uptime=$(cut -d' ' -f1 /proc/loadavg)"
    tot[$label]+="$t "; ai[$label]+="$a "; phys[$label]+="$p "; trk[$label]+="$k "
  done
done
med() { echo "$@" | tr ' ' '\n' | grep -v '^$' | sort -g | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
echo "--- medians over $rounds rounds (ms per tick)"
for v in "${variants[@]}"; do
  label=${v%%|*}
  echo "$label: total=$(med ${tot[$label]}) ai=$(med ${ai[$label]}) physics=$(med ${phys[$label]}) tracker=$(med ${trk[$label]})"
done
