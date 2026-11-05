#!/usr/bin/env bash
# Mobs rows of the final campaign: awake cows (500 / 2,000 / 5,000) with a viewer in range (v) and nobody in range (n), and 5,000 resting items (i); entity tick CPU of dbcraft against
# the vanilla Server thread's CPU per tick (docs/PERF-MOBS2.md method).  V D V D: repetition k = the real vanilla server over all scenarios (tools/entity/vanilla_mobs.py, a fresh JVM
# per repetition, -Xms1G -Xmx2G), then the dbcraft side over the same scenarios (tests/bench/mobs2/bench.sql: 150 warm-up ticks, VACUUM ANALYZE, 100 measured entity ticks, one
# transaction per tick, CPU = on-CPU time of the backend).  The load average is checked before every dbcraft scenario and before every vanilla repetition (the vanilla JVM's own
# scenarios follow each other without a gate: the gate would see the JVM's own load).
# usage: tools/scoreboard/cenv tools/scoreboard/mobs.sh OUTDIR [REPS] [SCENARIOS]
set -u
cd "$(dirname "$0")/../.."
out=$1; reps=${2:-3}; scen=${3:-500v 2000v 5000v 500n 2000n 5000n 5000i}
mkdir -p "$out"
waitload() {
  local t0=$SECONDS
  while [ "$(awk '{print ($1 <= 1.5) ? 1 : 0}' /proc/loadavg)" != 1 ] && [ $((SECONDS - t0)) -lt 900 ]; do sleep 5; done
  echo "load $(cut -d' ' -f1 /proc/loadavg) after waiting $((SECONDS - t0)) s" >> "$out/gate.log"
}
export PGDATABASE=dbcraft
tools/scoreboard/dbcraft.sh stop > /dev/null 2>&1
# resumable: the output directory is on disk (outside /dev/shm); a scenario that is already in vanilla.jsonl / dbcraft.txt for this repetition is not run again
have_v() { grep -q "\"rep\": $1, \"scenario\": \"$2\"" "$out/vanilla.jsonl" 2>/dev/null; }
have_d() { grep -q "^rep $1 | $3/$2 " "$out/dbcraft.txt" 2>/dev/null; }
for rep in $(seq 1 "$reps"); do
  miss=""
  for code in $scen; do have_v "$rep" "$code" || miss="$miss,$code"; done
  if [ -n "$miss" ]; then
    waitload
    python3 tools/entity/vanilla_mobs.py --dir /dev/shm/sb/mobvan --port 58607 --rcon 58608 --reps 1 --rep-offset $((rep - 1)) --scenarios "${miss#,}" --settle 30 --window 30 \
      --xms 1G --xmx 2G --tag final --out "$out/vanilla.jsonl" >> "$out/driver.log" 2>&1
  fi
  for code in $scen; do
    if ! have_d "$rep" "$code" final; then
      waitload
      echo "load before: $(cut -d' ' -f1 /proc/loadavg)" >> "$out/dbcraft.txt"
      # reset=1: the mob area is regenerated flat first (a world that other scenarios scribbled in gives mobs no lanes: the first campaign's in-view rows were inflated by that)
      tests/bench/mobs2/run_one.sh "$code" "$rep" final "$out/dbcraft.txt" -v warm=150 -v reset=1 2>&1 | grep -v NOTICE
    fi
    case "$code" in
      *n) have_d "$rep" "$code" final-nobody || { waitload; tests/bench/mobs2/run_one.sh "$code" "$rep" final-nobody "$out/dbcraft.txt" -v warm=150 -v reset=1 -v viewers=0 2>&1 | grep -v NOTICE; } ;;
      2000v|5000v) have_d "$rep" "$code" final-walk1 || { waitload; tests/bench/mobs2/run_one.sh "$code" "$rep" final-walk1 "$out/dbcraft.txt" -v warm=150 -v reset=1 -v walk=1.0 2>&1 | grep -v NOTICE; } ;;
    esac
  done
done
psql -X -q -c "truncate mc.entity, mc.play_out" > /dev/null 2>&1
echo "mobs done" >> "$out/driver.log"
