#!/usr/bin/env bash
# Record the command session (tests/e2e/cmd_steps.py) on a REAL vanilla 26.3 server: a fresh flat world, offline mode, operators Op1 .. Op4 of permission levels 1 .. 4,
# six players (Op4 Bob Cy Op1 Op2 Op3).  Writes $DBCRAFT_E2E_DIR/vanilla_cmd_<Player>.jsonl (default /tmp/dbcraft-e2e).  Takes about 8 minutes: a vanilla server never
# goes quiet, so every step waits for its timeout.
#
# usage: tests/e2e/record_commands.sh        environment: DBCRAFT_E2E_DIR, DBCRAFT_SERVER_JAR, JAVA, DBCRAFT_CMD_PORT (default 25612)
# needs: the official 26.3 server jar and Java 25.  The recordings contain Mojang data and stay out of git.
set -euo pipefail
cd "$(dirname "$0")/../.."
E2E=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e}; PORT=${DBCRAFT_CMD_PORT:-25612}; DIR=/tmp/vanilla-cmd-$PORT
JAR=${DBCRAFT_SERVER_JAR:-${DBCRAFT_HOME:-$HOME/.cache/dbcraft}/server-26.3.jar}; JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
[ -x "$JAVA" ] || JAVA=$(command -v java)
mkdir -p "$E2E"
[ -f "$JAR" ] || { echo "server jar not found: $JAR"; exit 1; }
if [ -f "$DIR/server.pid" ] && kill -0 "$(cat "$DIR/server.pid")" 2>/dev/null; then kill "$(cat "$DIR/server.pid")"; sleep 3; fi
rm -rf "$DIR"; mkdir -p "$DIR"; cp "$JAR" "$DIR/server.jar"
echo "eula=true" > "$DIR/eula.txt"
printf '%s\n' online-mode=false server-port=$PORT 'level-type=minecraft\:flat' view-distance=2 simulation-distance=2 network-compression-threshold=-1 \
  spawn-protection=0 enable-rcon=false enable-query=false motd=vanilla-cmd max-players=10 gamemode=creative difficulty=peaceful spawn-monsters=false \
  spawn-animals=false spawn-npcs=false generate-structures=false level-name=world white-list=false enforce-whitelist=false > "$DIR/server.properties"
python3 - "$DIR/ops.json" <<'PY'
import hashlib, json, sys, uuid
def offline(n):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + n).encode()).digest()); h[6] = (h[6] & 15) | 0x30; h[8] = (h[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(h)))
json.dump([{"uuid": offline(f"Op{i}"), "name": f"Op{i}", "level": i, "bypassesPlayerLimit": False} for i in (1, 2, 3, 4)], open(sys.argv[1], "w"))
PY
(cd "$DIR" && nohup "$JAVA" -Xmx1G -jar server.jar nogui > server.log 2>&1 & echo $! > "$DIR/server.pid")
trap 'kill "$(cat "$DIR/server.pid")" 2>/dev/null || true' EXIT
for i in $(seq 1 120); do grep -q "Done (" "$DIR/server.log" 2>/dev/null && break; sleep 1; done
grep -q "Done (" "$DIR/server.log" || { echo "vanilla did not start, see $DIR/server.log"; exit 1; }
python3 tests/e2e/cmd_probe.py --port "$PORT" --out "$E2E/vanilla_cmd" --wait 0.3
