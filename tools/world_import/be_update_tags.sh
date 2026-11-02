#!/usr/bin/env bash
# Reads (never runs) the 26.3 block entity classes with javap and reports which override getUpdateTag, i.e. which block entities put data into the chunk packet,
# and what that data is (saveCustomOnly = the save data without id/x/y/z; anything else is printed for a human to read).
# Scratch dir: /tmp/jar-import (class files extracted from the official server jar, outside git).
set -euo pipefail
S=${SCRATCH:-/tmp/jar-import}
mkdir -p "$S/cls"
if [ ! -f "$S/META-INF/versions/26.3/server-26.3.jar" ]; then unzip -q -o /tmp/jar-dl/server.jar META-INF/versions/26.3/server-26.3.jar -d "$S"; fi
cd "$S/cls"
unzip -q -o ../META-INF/versions/26.3/server-26.3.jar 'net/minecraft/world/level/block/entity/*' 'net/minecraft/world/level/block/entity/trialspawner/*' 'net/minecraft/world/level/block/entity/vault/*' 'net/minecraft/world/level/block/*Sulfur*' || true
echo "classes overriding getUpdateTag:"
for f in net/minecraft/world/level/block/entity/*BlockEntity.class net/minecraft/world/level/block/entity/*/*BlockEntity.class; do
  [ -f "$f" ] || continue
  cn=$(echo "${f%.class}" | tr / .)
  if javap -p -classpath . "$cn" 2>/dev/null | grep -q "getUpdateTag("; then
    body=$(javap -p -c -classpath . "$cn" 2>/dev/null | awk '/getUpdateTag\(/{f=1} f&&/invoke/{print} /areturn/{if(f){exit}}' | sed 's/.*\/\/ //' | tr '\n' ';' | cut -c1-200)
    echo "  $(basename "$cn")  ->  $body"
  fi
done
