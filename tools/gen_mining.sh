#!/usr/bin/env bash
# Derive what digging needs from the pinned vanilla server jar (docs/MINING-AND-COMMANDS.md): per block state the hardness (BlockState.getDestroySpeed) and the "requires the
# correct tool for drops" flag, answered by the game itself (tools/java/MiningDump.java boots the registries like the data generator does; no world or server is run), and the
# block loot tables (data/minecraft/loot_table/blocks/*.json, copied out of the jar).  Output in $DBCRAFT_REPORTS: block_mining.tsv and loot_blocks/*.json, loaded by
# tools/load_mining.py.  Idempotent: skipped when the files are newer than the jar.  Needs only Java 25.  Nothing of Mojang's is committed.
#
# usage: tools/gen_mining.sh [--force]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh
OUT="$DBCRAFT_REPORTS/block_mining.tsv"; LOOT="$DBCRAFT_REPORTS/loot_blocks"
[ -n "$JAVA" ] || { echo "Java 25 is needed (openjdk-25-jre-headless)"; exit 1; }
[ -f "$DBCRAFT_SERVER_JAR" ] || { echo "no server jar at $DBCRAFT_SERVER_JAR (run tools/bootstrap.sh)"; exit 1; }
if [ "${1:-}" != "--force" ] && [ -s "$OUT" ] && [ "$OUT" -nt "$DBCRAFT_SERVER_JAR" ] && [ -d "$LOOT" ]; then echo "up to date: $OUT"; exit 0; fi
work="$DBCRAFT_HOME/work/mining"; rm -rf "$work"; mkdir -p "$work" "$DBCRAFT_REPORTS"
( cd "$work" && unzip -q -o "$DBCRAFT_SERVER_JAR" 'META-INF/versions/*' 'META-INF/libraries/*' )
CP=$(find "$work/META-INF" -name '*.jar' | tr '\n' ':')
( cd "$work" && "$JAVA" -cp "$CP" "$ROOT/tools/java/MiningDump.java" > "$OUT.tmp" )       # (run from the work directory: the game writes a logs/ folder next to where it runs)
mv "$OUT.tmp" "$OUT"
( cd "$work" && unzip -q -o "$(ls META-INF/versions/*/server-*.jar | head -1)" 'data/minecraft/loot_table/blocks/*' -d jar )
rm -rf "$LOOT"; mkdir -p "$LOOT"; cp "$work"/jar/data/minecraft/loot_table/blocks/*.json "$LOOT/"
rm -rf "$work"
echo "wrote $OUT ($(grep -c "^B" "$OUT") blocks, $(grep -c "^X" "$OUT") state exceptions, $(grep -c "^O" "$OUT") classes overriding getDestroyProgress) and $(ls "$LOOT" | wc -l) block loot tables"
