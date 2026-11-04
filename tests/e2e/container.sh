#!/usr/bin/env bash
# The container comparison against the REAL vanilla 26.3 server: for each scenario/seed, vanilla records a randomized click sequence (empty claims), dbcraft replays the same
# actions, and every step (the packets of the click and the full menu state after it) must be equal.  With CLAIMS=1 both servers then replay claiming what a real client
# predicts (changedSlots / carried item), which must silence them equally.
#
#   tests/e2e/container.sh VANILLA_PORT RCON_PORT DBCRAFT_PORT 'psql command line of the dbcraft database' [scenario:seed:steps ...]
#
#   vanilla: online-mode=false, survival, peaceful, no mobs, flat world, spawn protection 0, enable-rcon=true (password dbcraft-cont; RCON_PW overrides), the player "Cont" is made an operator
#   dbcraft: a running dev gateway (call net.run(DBCRAFT_PORT)) on a migrated database with the reports, the datapack, the static packets and the recipes loaded
#            (tools/setup-db.sh does all of that); survival, view distance 2
# After the scenarios: the sneaking plan (container_plan_sneak.py) and the furnace / blast furnace / smoker sequences (furnace_probe.py).
# Scenarios: inv (the player's menu with its 2x2 grid), craft (the same, crafting-heavy), table (crafting table), chest, double (all four facings: seeds 1-4), barrel, ender.
# Default: the set the results in docs/CONTAINERS.md come from.  Recordings (Mojang data) go to $DBCRAFT_E2E_DIR (default /tmp/dbcraft-e2e-cont) and are never committed.
set -uo pipefail
cd "$(dirname "$0")/../.."
VP=${1:?vanilla port}; RP=${2:?rcon port}; DP=${3:?dbcraft port}; PSQL=${4:?psql command}; shift 4
D=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e-cont}; mkdir -p "$D"
RPW=${RCON_PW:-dbcraft-cont}
SET=("$@"); [ ${#SET[@]} = 0 ] && SET=(inv:1:40 inv:2:40 craft:1:40 craft:2:40 table:1:40 table:2:40 chest:1:40 chest:2:40 double:1:40 double:2:40 double:3:40 double:4:40 barrel:1:30 ender:1:30)
rc=0
for spec in "${SET[@]}"; do
  IFS=: read -r S SEED N <<< "$spec"
  A="$D/vanilla_${S}_$SEED.json"
  python3 tests/e2e/container_probe.py --mode vanilla --port "$VP" --rcon "$RP" --rcon-pw "$RPW" --scenario "$S" --seed "$SEED" --steps "$N" --out "$A" > "$D/vanilla_${S}_$SEED.log" 2>&1 || { echo "FAIL $spec: vanilla run"; rc=1; continue; }
  python3 tests/e2e/container_probe.py --mode dbcraft --port "$DP" --psql "$PSQL" --actions "$A" --out "$D/ours_${S}_$SEED.json" > "$D/ours_${S}_$SEED.log" 2>&1 || { echo "FAIL $spec: dbcraft run"; rc=1; continue; }
  python3 tests/e2e/compare_container.py "$A" "$D/ours_${S}_$SEED.json" --quiet || rc=1
  if [ "${CLAIMS:-0}" = 1 ]; then
    python3 tests/e2e/container_probe.py --mode vanilla --port "$VP" --rcon "$RP" --rcon-pw "$RPW" --actions "$A" --claims --out "$D/vclaims_${S}_$SEED.json" > "$D/vclaims_${S}_$SEED.log" 2>&1 || { echo "FAIL $spec: vanilla claims run"; rc=1; continue; }
    python3 tests/e2e/container_probe.py --mode dbcraft --port "$DP" --psql "$PSQL" --actions "$A" --claims --out "$D/oclaims_${S}_$SEED.json" > "$D/oclaims_${S}_$SEED.log" 2>&1 || { echo "FAIL $spec: dbcraft claims run"; rc=1; continue; }
    python3 tests/e2e/compare_container.py "$D/vclaims_${S}_$SEED.json" "$D/oclaims_${S}_$SEED.json" --quiet || rc=1
  fi
done
# sneaking with an item in the hand does not open the chest (vanilla uses the item instead); standing does
python3 tests/e2e/container_plan_sneak.py "$D/plan_sneak.json"
python3 tests/e2e/container_probe.py --mode vanilla --port "$VP" --rcon "$RP" --rcon-pw "$RPW" --actions "$D/plan_sneak.json" --out "$D/vanilla_sneak.json" > "$D/vanilla_sneak.log" 2>&1 || { echo "FAIL sneak: vanilla run"; rc=1; }
python3 tests/e2e/container_probe.py --mode dbcraft --port "$DP" --psql "$PSQL" --actions "$D/plan_sneak.json" --out "$D/ours_sneak.json" > "$D/ours_sneak.log" 2>&1 || { echo "FAIL sneak: dbcraft run"; rc=1; }
python3 tests/e2e/compare_container.py "$D/vanilla_sneak.json" "$D/ours_sneak.json" --quiet || rc=1
# furnaces: the sequence of the container packets of 14 seconds of smelting (see furnace_probe.py)
for spec in furnace:minecraft:raw_iron blast:minecraft:raw_iron smoker:minecraft:beef; do
  K=${spec%%:*}; IT=${spec#*:}
  python3 tests/e2e/furnace_probe.py record --mode vanilla --port "$VP" --rcon "$RP" --rcon-pw "$RPW" --kind "$K" --input "$IT" --out "$D/furnace_v_$K.json" > "$D/furnace_v_$K.log" 2>&1 || { echo "FAIL $K: vanilla run"; rc=1; continue; }
  python3 tests/e2e/furnace_probe.py record --mode dbcraft --port "$DP" --psql "$PSQL" --kind "$K" --input "$IT" --out "$D/furnace_o_$K.json" > "$D/furnace_o_$K.log" 2>&1 || { echo "FAIL $K: dbcraft run"; rc=1; continue; }
  python3 tests/e2e/furnace_probe.py compare "$D/furnace_v_$K.json" "$D/furnace_o_$K.json" | tail -2 | tr '\n' ' '; echo "($K)"
  python3 tests/e2e/furnace_probe.py compare "$D/furnace_v_$K.json" "$D/furnace_o_$K.json" > /dev/null || rc=1
done
[ $rc = 0 ] && echo "ALL CONTAINER COMPARISONS PASSED" || echo "SOME CONTAINER COMPARISONS FAILED"
exit $rc
