#!/usr/bin/env bash
# Waits until the total size of the overworld region files stops changing (generation finished), polling every 10 s; gives up after 15 minutes.
D=${VANILLA_IMPORT_DIR:-/tmp/vanilla-import}/world/dimensions/minecraft/overworld/region
last=-1; same=0
for i in $(seq 1 90); do
  now=$(cat "$D"/*.mca 2>/dev/null | wc -c)
  if [ "$now" = "$last" ]; then same=$((same + 1)); else same=0; fi
  last=$now
  [ "$same" -ge 4 ] && { echo "stable at $now bytes after $((i * 10)) s"; exit 0; }
  sleep 10
done
echo "not stable after 15 minutes (last $last bytes)"
