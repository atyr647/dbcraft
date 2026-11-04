#!/usr/bin/env bash
# The whole V/D comparison: repetition k = the real vanilla server over all scenarios (tools/entity/vanilla_mobs.py, a fresh JVM), then the dbcraft side over the same scenarios
# (tests/bench/mobs2/after.sh: old, new, old-walk1, new-walk1, split).  Alternates V D V D V D (the vanilla JVM is not stopped between scenarios: a stopped server times its client out).
# usage: tests/bench/mobs2/campaign.sh OUTDIR [REPS] [SCENARIOS]        env: PGHOST PGPORT PGUSER, VAN_DIR (default /dev/shm/mob2/van), RCON_TIMEOUT
set -uo pipefail
cd "$(dirname "$0")/../../.."
out=$1; reps=${2:-3}; scen=${3:-2000v,5000v,2000n,5000n,500v,5000i}
mkdir -p "$out"
for rep in $(seq 1 "$reps"); do
  python3 tools/entity/vanilla_mobs.py --dir "${VAN_DIR:-/dev/shm/mob2/van}" --reps 1 --rep-offset $((rep - 1)) --scenarios "$scen" --settle 30 --window 30 --tag final --out "$out/vanilla.jsonl" >> "$out/driver.log" 2>&1
  for code in ${scen//,/ }; do
    tests/bench/mobs2/after.sh "$code" "$rep" "$out" >> "$out/driver.log" 2>&1
  done
done
echo campaign done >> "$out/driver.log"
