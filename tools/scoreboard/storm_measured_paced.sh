#!/usr/bin/env bash
# The paced in-database storm (tests/bench/joinbudget, docs/PERF-JOINBUDGET.md) on the two clusters of storm_measured.sh, alternating before / after; one JSON line per run is
# appended to docs/perf-storm-measured-paced.txt (CPU time per tick = the tick backend's on-CPU time from /proc/self/schedstat, so load matters little).
#   usage: tools/scoreboard/storm_measured_paced.sh JOINERS ONLINE [REPS]
cd "$(dirname "$0")/../.."
HEAD_TREE=$(pwd)
BT=/dev/shm/stormm_btree
J=${1:-50}; O=${2:-20}; REPS=${3:-1}
OUT=$HEAD_TREE/docs/perf-storm-measured-paced.txt
for rep in $(seq 1 "$REPS"); do
  for w in before after; do
    if [ $w = before ]; then d=$BT; p=56610; else d=$HEAD_TREE; p=56600; fi
    grep -q "\"label\": \"$w ${J}into${O} r$rep\"" "$OUT" 2>/dev/null && continue
    L=$(cut -d' ' -f1 /proc/loadavg)
    s=$(date +%s)
    line=$(cd "$d" && JB_PORT=$p JB_DB=jb python3 tests/bench/joinbudget/run.py --joiners "$J" --online "$O" --budget 25 --vd 10 --side 30 --walk 0.2 --label "$w ${J}into${O} r$rep" --json)
    echo "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); d['load_at_start']=$L; d['seconds']=$(date +%s)-$s; print(json.dumps(d))" >> "$OUT"
    echo "$w ${J}into${O} r$rep: $(( $(date +%s) - s )) s, load at start $L"
  done
done
