#!/usr/bin/env bash
# Generate the real-terrain test world of the light tests with the REAL vanilla 26.3 server: seed 7041, 512 chunks force-loaded around the spawn (swamp, ocean, grass land, hills,
# caves with lava and glow lichen, a village), saved and stopped, written to $LT_WORLD (default /root/lt/van1/world.pristine, a stopped world: copy it, never run on it).
# Mojang data: never committed.  About 8 minutes on the 4-core container.  Then:
#   python3 tools/world_import.py $LT_WORLD --replace --work /root/lt/imp --no-players --no-level          (into a scratch database)
#   tests/light/compare_edits.py --world $LT_WORLD                                                           (the edits against the real server)
#   tests/light/compare_import.sql                                                                            (the light of the imported chunks recomputed)
# usage: tests/light/vanilla_world.sh          environment: LT_DIR (default /root/lt/van1), LT_MC (25860), LT_RCON (25861), JAVA, DBCRAFT_SERVER_JAR
set -euo pipefail
cd "$(dirname "$0")/../.."
D=${LT_DIR:-/root/lt/van1}; MC=${LT_MC:-25860}; RC=${LT_RCON:-25861}
JAR=${DBCRAFT_SERVER_JAR:-${DBCRAFT_HOME:-$HOME/.cache/dbcraft}/server-26.3.jar}; JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
export RCON_PORT=$RC RCON_PW=lt-light
rm -rf "$D"; mkdir -p "$D"; cp "$JAR" "$D/server.jar"; echo eula=true > "$D/eula.txt"
printf '%s\n' online-mode=false server-port=$MC 'level-type=minecraft\:normal' level-seed=7041 view-distance=6 simulation-distance=2 network-compression-threshold=-1 spawn-protection=0 \
  enable-rcon=true rcon.port=$RC rcon.password=lt-light motd=lt max-players=4 gamemode=creative difficulty=peaceful spawn-monsters=false spawn-animals=false spawn-npcs=false \
  generate-structures=true level-name=world white-list=false enforce-whitelist=false max-tick-time=-1 pause-when-empty-seconds=-1 > "$D/server.properties"
( cd "$D" && exec "$JAVA" -Xms1G -Xmx2G -jar server.jar nogui ) > "$D/server.log" 2>&1 &
echo $! > "$D/pid"
for i in $(seq 1 120); do grep -q "Done (" "$D/server.log" 2>/dev/null && break; sleep 1; done
# four boxes of 128 / 256 chunks (the limit of /forceload is 256 chunks per command): x -256 .. 255, z -128 .. 127
for box in "-128 -128 127 127" "128 -128 255 127" "-256 -128 -129 127"; do python3 tools/entity/rcon.py cmd "forceload add $box"; done
for i in $(seq 1 600); do
  python3 tools/entity/rcon.py cmd "execute if loaded 255 64 127" | grep -q "passed" && python3 tools/entity/rcon.py cmd "execute if loaded -256 64 -128" | grep -q "passed" && break
  sleep 2
done
sleep 10
python3 tools/entity/rcon.py cmd "forceload remove all"
python3 tools/entity/rcon.py cmd "save-all flush"
python3 tools/entity/rcon.py cmd "stop"
for i in $(seq 1 60); do kill -0 "$(cat "$D/pid")" 2>/dev/null || break; sleep 1; done
rm -rf "$D/world.pristine"; cp -r "$D/world" "${LT_WORLD:-$D/world.pristine}"
echo "world: ${LT_WORLD:-$D/world.pristine}"
