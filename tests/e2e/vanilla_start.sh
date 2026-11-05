#!/usr/bin/env bash
# Start a throwaway REAL vanilla 26.3 server for a recording: fresh flat survival world, normal difficulty, no mobs, offline mode, no compression, view distance 3,
# RCON password dbcraft-e2e.  usage: tests/e2e/vanilla_start.sh DIR PORT RCON_PORT       stop it with:  tests/e2e/vanilla_start.sh DIR stop
# (-Xms1G -Xmx2G: a larger heap is OOM-killed in the container)
D=${1:?dir}; P=${2:?port}
JAR=${DBCRAFT_SERVER_JAR:-${DBCRAFT_HOME:-$HOME/.cache/dbcraft}/server-26.3.jar}; JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
if [ "$P" = stop ]; then kill "$(cat "$D/server.pid")" 2>/dev/null; exit 0; fi
R=${3:?rcon port}
mkdir -p "$D"; cd "$D" || exit 1
cp -n "$JAR" server.jar
rm -rf world usercache.json ops.json server.log
echo eula=true > eula.txt
# operators (OPS="Surv,Obs"): ops.json with the OFFLINE-mode uuids (an `op` over RCON for a name that never joined stores a different uuid in offline mode)
python3 - "${OPS:-}" > ops.json <<'PY'
import hashlib, json, sys, uuid
def off(n):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + n).encode()).digest()); h[6] = (h[6] & 0x0f) | 0x30; h[8] = (h[8] & 0x3f) | 0x80; return str(uuid.UUID(bytes=bytes(h)))
print(json.dumps([{"uuid": off(n), "name": n, "level": 4, "bypassesPlayerLimit": False} for n in sys.argv[1].split(",") if n]))
PY
printf '%s\n' online-mode=false server-port=$P 'level-type=minecraft\:flat' view-distance=3 simulation-distance=3 network-compression-threshold=-1 spawn-protection=0 \
  enable-rcon=true rcon.port=$R rcon.password=dbcraft-e2e motd=diff max-players=10 gamemode=survival difficulty=normal spawn-monsters=false spawn-animals=false spawn-npcs=false \
  generate-structures=false level-name=world white-list=false enforce-whitelist=false > server.properties
nohup "$JAVA" -Xms1G -Xmx2G -jar server.jar nogui > server.log 2>&1 &
echo $! > server.pid
for i in $(seq 1 120); do grep -q "Done (" server.log && break; sleep 1; done
tail -2 server.log
