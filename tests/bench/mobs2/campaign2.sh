#!/usr/bin/env bash
# V D V D V D: repetition k = the real vanilla server over all scenarios (a fresh JVM), then the dbcraft side over the same scenarios (tests/bench/mobs2/after2.sh).
# usage: tests/bench/mobs2/campaign2.sh OUTDIR [REPS] [SCENARIOS]      env: PGHOST PGPORT PGUSER OLD_DB NEW_DB, VAN_DIR, VAN_PORT, RCON_TIMEOUT
set -uo pipefail
cd "$(dirname "$0")/../../.."
out=$1; reps=${2:-3}; scen=${3:-500n,2000n,5000n,2000v,5000v}
mkdir -p "$out"
for rep in $(seq 1 "$reps"); do
  python3 tools/entity/vanilla_mobs.py --dir "${VAN_DIR:-/dev/shm/mob3/van}" --port "${VAN_PORT:-25961}" --rcon "$(( ${VAN_PORT:-25961} + 1 ))" --reps 1 --rep-offset $((rep - 1)) --scenarios "$scen" \
      --settle 30 --window 30 --xms 1G --xmx 2G --tag part2 --out "$out/vanilla.jsonl" >> "$out/driver.log" 2>&1
  for code in ${scen//,/ }; do
    tests/bench/mobs2/after2.sh "$code" "$rep" "$out" >> "$out/driver.log" 2>&1
  done
done
echo campaign done >> "$out/driver.log"
