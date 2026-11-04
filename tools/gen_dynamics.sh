#!/usr/bin/env bash
# Derive the world-dynamics reference data from the pinned vanilla server jar: per block state its class chain, random-tick flag, fluid state, collision shape,
# face sturdiness, and the face-occlusion table fluids use.  The jar's own registries answer (tools/java/DynDump.java boots them like the data generator does and
# reads the data; no world or server is run).  Output: $DBCRAFT_REPORTS/dyn_states.tsv, loaded by tools/load_dynamics.py.  Idempotent: skipped when the file is
# newer than the jar.  Needs only Java 25 (the source launcher compiles the one file).  Nothing of Mojang's is committed.
#
# usage: tools/gen_dynamics.sh [--force]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh
OUT="$DBCRAFT_REPORTS/dyn_states.tsv"
[ -n "$JAVA" ] || { echo "Java 25 is needed (openjdk-25-jre-headless)"; exit 1; }
[ -f "$DBCRAFT_SERVER_JAR" ] || { echo "no server jar at $DBCRAFT_SERVER_JAR (run tools/bootstrap.sh)"; exit 1; }
if [ "${1:-}" != "--force" ] && [ -s "$OUT" ] && [ "$OUT" -nt "$DBCRAFT_SERVER_JAR" ]; then echo "up to date: $OUT"; exit 0; fi
work="$DBCRAFT_HOME/work/dyn"; rm -rf "$work"; mkdir -p "$work" "$DBCRAFT_REPORTS"
( cd "$work" && unzip -q -o "$DBCRAFT_SERVER_JAR" 'META-INF/versions/*' 'META-INF/libraries/*' )
CP=$(find "$work/META-INF" -name '*.jar' | tr '\n' ':')
( cd "$work" && "$JAVA" -cp "$CP" "$ROOT/tools/java/DynDump.java" > "$OUT.tmp" )       # (run from the work directory: the game writes a logs/ folder next to where it runs)
mv "$OUT.tmp" "$OUT"
rm -rf "$work"
echo "wrote $OUT ($(grep -c '^S' "$OUT") states, $(grep -c '^H' "$OUT") collision shapes, $(grep -c '^O' "$OUT") occluding pairs)"
