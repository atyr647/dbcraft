#!/usr/bin/env bash
# The survival comparison: record the REAL vanilla server (once), replay the same scripted clients against dbcraft over TCP, compare the packets.
#
#   tests/e2e/survival.sh record VANILLA_PORT            vanilla must run in survival, difficulty normal, no mobs (gamerule spawn_mobs false), world spawn 0 -60 0,
#                                                        gamerule respawn_radius 0, and the player "Surv" must be an operator (see survival_probe.py).  Writes
#                                                        $DBCRAFT_E2E_DIR/vanilla_<scenario>_{surv,obs}.jsonl   (default /tmp/dbcraft-e2e-surv)
#   tests/e2e/survival.sh compare DBCRAFT_PORT           against a running dbcraft server (dev gateway or the Rust gateway: survival, normal, spawn 0.5 -60 0.5, "Surv" an op,
#                                                        no mobs/entities, view distance 3).  PGHOST/PGPORT/PGDATABASE name its database (only the eat scenario needs psql:
#                                                        dbcraft cannot give a player the Hunger effect, so the food level the vanilla run reached is set with UPDATE).
# Recordings contain Mojang data (registries, chunks) and are never committed.
set -uo pipefail
cd "$(dirname "$0")/../.."
E2E=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e-surv}; mkdir -p "$E2E"
case "${1:-}" in
  record)
    for s in fall kill void; do python3 tests/e2e/survival_probe.py $s --port "${2:?vanilla port}" --out "$E2E/vanilla" | tail -1; done
    python3 tests/e2e/survival_probe.py eat --drain --port "$2" --out "$E2E/vanilla" | tee "$E2E/vanilla_eat.log" | tail -2 ;;
  compare)
    rc=0
    for s in fall kill void; do python3 tests/e2e/survival_probe.py $s --port "${2:?dbcraft port}" --out "$E2E/ours" > /dev/null || rc=1; python3 tests/e2e/compare_survival.py $s "$E2E/vanilla" "$E2E/ours" || rc=1; done
    food=$(sed -n 's/^food state before eating: (\([0-9.]*\), \([0-9]*\), \([0-9.]*\))/\2,\3/p' "$E2E/vanilla_eat.log" 2>/dev/null | head -1)
    python3 tests/e2e/survival_probe.py eat --set-food "${food:-19,0.0}" --port "$2" --out "$E2E/ours" > /dev/null || rc=1; python3 tests/e2e/compare_survival.py eat "$E2E/vanilla" "$E2E/ours" || rc=1
    [ $rc = 0 ] && echo "ALL SURVIVAL COMPARISONS PASSED" || echo "SOME SURVIVAL COMPARISONS FAILED"; exit $rc ;;
  *) echo "usage: $0 record VANILLA_PORT | compare DBCRAFT_PORT"; exit 2 ;;
esac
