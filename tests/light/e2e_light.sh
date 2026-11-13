#!/usr/bin/env bash
# light_update packets, the real vanilla 26.3 server against dbcraft's gateway: both get the same edits next to the border of the area a scripted client tracks;
# every light_update (and block) packet the client receives is recorded and compared (tests/e2e/light_probe.py, tests/e2e/compare_light.py).
#
# usage: tests/light/e2e_light.sh        environment (all optional): LT_DIR (default /root/lt/e2e), LT_PGDATA / LT_PGPORT (a private cluster, default /dev/shm/lt_pg2, 56852),
#        LT_MC (vanilla port 25870), LT_RCON (25871), LT_GW (dbcraft gateway port 25872)
# needs: the 26.3 server jar and Java 25, the reports (tools/bootstrap.sh), light data (tools/gen_light.sh), PostgreSQL with plpython3u.  The recordings are Mojang data: never committed.
set -uo pipefail
cd "$(dirname "$0")/../.."
D=${LT_DIR:-/root/lt/e2e}; MC=${LT_MC:-25870}; RC=${LT_RCON:-25871}; GW=${LT_GW:-25872}
export DBCRAFT_PGDATA=${LT_PGDATA:-/dev/shm/lt_pg2} DBCRAFT_PGPORT=${LT_PGPORT:-56852}
JAR=${DBCRAFT_SERVER_JAR:-${DBCRAFT_HOME:-$HOME/.cache/dbcraft}/server-26.3.jar}; JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
mkdir -p "$D"; export DBCRAFT_E2E_DIR=$D
echo "=== vanilla: a fresh flat world, view distance 2"
rm -rf "$D/van"; mkdir -p "$D/van"; cp "$JAR" "$D/van/server.jar"; echo eula=true > "$D/van/eula.txt"
printf '%s\n' online-mode=false server-port=$MC 'level-type=minecraft\:flat' view-distance=2 simulation-distance=2 network-compression-threshold=-1 spawn-protection=0 enable-rcon=true \
  rcon.port=$RC rcon.password=lt-light motd=lt max-players=4 gamemode=creative difficulty=peaceful spawn-monsters=false spawn-animals=false spawn-npcs=false generate-structures=false \
  level-name=world white-list=false enforce-whitelist=false max-tick-time=-1 pause-when-empty-seconds=-1 > "$D/van/server.properties"
( cd "$D/van" && exec "$JAVA" -Xms1G -Xmx2G -jar server.jar nogui ) > "$D/van/server.log" 2>&1 &
echo $! > "$D/van/pid"
for i in $(seq 1 120); do grep -q "Done (" "$D/van/server.log" 2>/dev/null && break; sleep 1; done
python3 tools/capture_vanilla.py --port $MC --seconds 3 --name Warm --out "$D/warm.jsonl" > /dev/null          # generates the area around the spawn
python3 tests/e2e/light_probe.py --mode vanilla --port $MC --rcon $RC --rcon-pw lt-light --out "$D/vanilla_light.json" > "$D/vanilla_light.log" 2>&1
kill "$(cat "$D/van/pid")" 2>/dev/null
echo "=== dbcraft: database, gateway"
tests/e2e/setup.sh > "$D/setup.log" 2>&1 || { tail -5 "$D/setup.log"; exit 1; }
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=dbcraft
psql -X -q -c "update mc.server_property set value = 'creative' where key = 'gamemode'" -c "select net.sync_settings()" > /dev/null
tests/e2e/gateway.sh start $GW
python3 tests/e2e/light_probe.py --mode dbcraft --port $GW --psql "psql -X -At -h /tmp -p $DBCRAFT_PGPORT -U postgres dbcraft" --out "$D/ours_light.json" > "$D/ours_light.log" 2>&1
tests/e2e/gateway.sh stop
echo "=== compare"
python3 tests/e2e/compare_light.py "$D/vanilla_light.json" "$D/ours_light.json"
