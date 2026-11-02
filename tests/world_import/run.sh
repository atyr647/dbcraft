#!/usr/bin/env bash
# File-based tests of the world importer/exporter.  Skips (exit 0, with a notice) the parts whose inputs are absent: the generated vanilla world is Mojang data and
# is never committed (generate it with tools/world_import/vanilla_world.sh, see docs/WORLD-IMPORT.md).
#   tests/world_import/run.sh
# env: WORLD (default /tmp/vanilla-import/world.pristine: a stopped, untouched vanilla world), CAPTURE (vanilla's chunk packets of that world, optional),
#      libpq variables for a database with the dbcraft schema (PGHOST/PGPORT/PGUSER/PGDATABASE or DBCRAFT_PSQL).  WARNING: it replaces the imported
#      overworld chunks of that database.  VANILLA=1 also starts a real vanilla server on the exported world (needs /tmp/jar-dl/server.jar and Java 25).
set -uo pipefail
cd "$(dirname "$0")/../.."
WORLD=${WORLD:-/tmp/vanilla-import/world.pristine}
fail=0
step() { echo "--- $*"; }

step "anvil/NBT unit tests (standard library)"
python3 -I tests/world_import/test_anvil.py "$WORLD/dimensions/minecraft/overworld/region" || fail=1

if [ ! -d "$WORLD/dimensions/minecraft/overworld/region" ]; then
  echo "SKIP: no vanilla world at $WORLD (tools/world_import/vanilla_world.sh start ... stop; cp -r world world.pristine): import/export tests not run"
  exit $fail
fi
if ! psql -X -q -At -c "select 1 from mc.chunk limit 1" >/dev/null 2>&1; then
  echo "SKIP: no database with the dbcraft schema reachable (set PGHOST/PGPORT/PGUSER/PGDATABASE): import/export tests not run"
  exit $fail
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

step "import the vanilla world"
python3 tools/world_import.py "$WORLD" --replace --work "$T/imp1" | tail -1 || fail=1
psql -X -q -At -f tests/world_import/digest.sql > "$T/digest1.txt"; cat "$T/digest1.txt"

if [ -n "${CAPTURE:-}" ] && [ -f "$CAPTURE" ]; then
  step "chunk packets against the real server's (CAPTURE=$CAPTURE)"
  python3 -I tests/world_import/compare_chunks.py "$CAPTURE" ${EXCLUDE_NEAR:+--exclude-near="$EXCLUDE_NEAR"} | tail -9 || fail=1
else
  echo "SKIP: no CAPTURE (a recording of vanilla's chunk packets, tools/world_import/capture_area.py): packet comparison not run"
fi

step "export, then import the export again: every component must be identical"
python3 tools/world_export.py "$T/export/world" || fail=1
python3 tools/world_import.py "$T/export/world" --replace --work "$T/imp2" --player-names "$WORLD/../usercache.json" | tail -1 || fail=1
psql -X -q -At -f tests/world_import/digest.sql > "$T/digest2.txt"
if diff "$T/digest1.txt" "$T/digest2.txt"; then echo "ok   round trip: import -> export -> import gives the same chunks, heightmaps, counts, block entities"; else echo "FAIL round trip"; fail=1; fi

if [ "${VANILLA:-0}" = 1 ]; then
  step "a real vanilla server on the export (edits + RCON sampling)"
  V=/tmp/vanilla-verify
  python3 tests/world_import/verify_export.py prepare "$T/samples.json" || fail=1
  rm -rf "$T/export2"; python3 tools/world_export.py "$T/export2/world" | tee "$T/exp.txt" || fail=1
  SEED=$(sed -n 's/.*level-seed=\(-\?[0-9]*\).*/\1/p' "$T/exp.txt")
  rm -rf "$V/world"; mkdir -p "$V"; cp -r "$T/export2/world" "$V/world"
  VANILLA_IMPORT_DIR=$V LEVEL_SEED=$SEED tools/world_import/vanilla_world.sh start
  for i in $(seq 1 60); do grep -q "Done (" "$V/server.log" 2>/dev/null && break; sleep 2; done
  RCON_PORT=25718 RCON_PW=importtest python3 tests/world_import/verify_export.py check "$T/samples.json" || fail=1
  grep -E "ERROR|atafix|Failed" "$V/server.log" | grep -v "Unsafe" && { echo "FAIL: errors in the vanilla log"; fail=1; }
  VANILLA_IMPORT_DIR=$V tools/world_import/vanilla_world.sh stop
fi
[ $fail = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $fail
