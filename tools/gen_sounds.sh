#!/usr/bin/env bash
# Derive the block sound types from the pinned vanilla server jar: per block the SoundType (volume, pitch and the break / step / place / hit / fall sound events) the game itself answers
# (tools/java/SoundDump.java boots the registries like the data generator does and reads the data; no world or server is run).  Output: $DBCRAFT_REPORTS/block_sounds.tsv, loaded by
# tools/load_sounds.py.  Idempotent: skipped when the file is newer than the jar.  Needs only Java 25.  Nothing of Mojang's is committed.
#
# usage: tools/gen_sounds.sh [--force]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh
OUT="$DBCRAFT_REPORTS/block_sounds.tsv"
[ -n "$JAVA" ] || { echo "Java 25 is needed (openjdk-25-jre-headless)"; exit 1; }
[ -f "$DBCRAFT_SERVER_JAR" ] || { echo "no server jar at $DBCRAFT_SERVER_JAR (run tools/bootstrap.sh)"; exit 1; }
if [ "${1:-}" != "--force" ] && [ -s "$OUT" ] && [ "$OUT" -nt "$DBCRAFT_SERVER_JAR" ]; then echo "up to date: $OUT"; exit 0; fi
work="$DBCRAFT_HOME/work/sounds"; rm -rf "$work"; mkdir -p "$work" "$DBCRAFT_REPORTS"
( cd "$work" && unzip -q -o "$DBCRAFT_SERVER_JAR" 'META-INF/versions/*' 'META-INF/libraries/*' )
CP=$(find "$work/META-INF" -name '*.jar' | tr '\n' ':')
( cd "$work" && "$JAVA" -cp "$CP" "$ROOT/tools/java/SoundDump.java" > "$OUT.tmp" )       # (run from the work directory: the game writes a logs/ folder next to where it runs)
mv "$OUT.tmp" "$OUT"
rm -rf "$work"
echo "wrote $OUT ($(grep -c "^T" "$OUT") sound types, $(grep -c "^B" "$OUT") blocks, $(grep -c "^X" "$OUT") state exceptions)"
