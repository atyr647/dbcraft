#!/usr/bin/env bash
# The sound comparison: record the REAL vanilla server (once), replay the same scripted clients against dbcraft over TCP, compare the sounds (and the packets that fix their order).
#
#   tests/e2e/sound.sh record VANILLA_PORT        a vanilla server as tests/e2e/vanilla_start.sh makes it (OPS=Surv,Obs, world spawn 0 -60 0, respawn_radius 0): records the scenarios
#                                                 place dig chest (sound_probe.py) and fall kill void eat (survival_probe.py) into $DBCRAFT_E2E_DIR (default /tmp/dbcraft-e2e-sound)
#   tests/e2e/sound.sh compare DBCRAFT_PORT [SCENARIO...]
#                                                 against a running dbcraft server (dev gateway: survival, normal, view distance 3, "Surv" and "Obs" operators; PGHOST/PGPORT/PGDATABASE
#                                                 name its database: the eat scenario sets the food level the vanilla run reached with psql)
# Recordings contain Mojang data and are never committed.
set -uo pipefail
cd "$(dirname "$0")/../.."
E2E=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e-sound}; mkdir -p "$E2E"
case "${1:-}" in
  record)
    for s in place dig chest; do python3 tests/e2e/sound_probe.py $s --port "${2:?vanilla port}" --out "$E2E/vanilla" | tail -1; done
    for s in fall kill void; do python3 tests/e2e/survival_probe.py $s --port "$2" --out "$E2E/vanilla" | tail -1; done
    python3 tests/e2e/survival_probe.py eat --drain --port "$2" --out "$E2E/vanilla" | tee "$E2E/vanilla_eat.log" | tail -2 ;;
  compare)
    P=${2:?dbcraft port}; shift 2; rc=0
    SCN=${*:-place chest fall kill eat}
    for s in $SCN; do
      case $s in
        place|dig|chest) python3 tests/e2e/sound_probe.py $s --dbcraft --port "$P" --out "$E2E/ours" > /dev/null || rc=1 ;;
        eat) food=$(sed -n 's/^food state before eating: (\([0-9.]*\), \([0-9]*\), \([0-9.]*\))/\2,\3/p' "$E2E/vanilla_eat.log" 2>/dev/null | head -1)
             python3 tests/e2e/survival_probe.py eat --set-food "${food:-19,0.0}" --port "$P" --out "$E2E/ours" > /dev/null || rc=1 ;;
        *) python3 tests/e2e/survival_probe.py $s --port "$P" --out "$E2E/ours" > /dev/null || rc=1 ;;
      esac
      python3 tests/e2e/compare_sound.py $s "$E2E/vanilla" "$E2E/ours" || rc=1
    done
    [ $rc = 0 ] && echo "ALL SOUND COMPARISONS PASSED" || echo "SOME SOUND COMPARISONS FAILED"; exit $rc ;;
  *) echo "usage: $0 record VANILLA_PORT | compare DBCRAFT_PORT [SCENARIO...]"; exit 2 ;;
esac
