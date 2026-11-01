#!/usr/bin/env bash
# Record the baselines the end-to-end comparisons need from a REAL vanilla 26.3 server: what it sends a client that joins, changes blocks, walks across
# chunk borders, and shares the world with another player.  Starts its own server (fresh flat world, offline mode, view distance 2, no compression,
# peaceful, no mobs) in /tmp/vanilla-int on port 25611 unless one is already listening there.
#
# usage: tests/e2e/record_vanilla.sh                  environment: DBCRAFT_E2E_DIR (default /tmp/dbcraft-e2e), DBCRAFT_SERVER_JAR (default /tmp/jar-dl/server.jar),
#                                                       JAVA (default the Java 25 under /usr/lib/jvm), DBCRAFT_REPORTS
# needs: the official 26.3 server jar (SHA-1 33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c, pinned in adacraft) and Java 25.  The recordings contain Mojang data
#        (registries, chunks) and stay out of git.
set -euo pipefail
cd "$(dirname "$0")/../.."
E2E=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e}; PORT=25611; DIR=/tmp/vanilla-int
JAR=${DBCRAFT_SERVER_JAR:-/tmp/jar-dl/server.jar}; JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
mkdir -p "$E2E"
listening() { python3 - "$PORT" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(0.3)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); s.close()
except OSError: sys.exit(1)
PY
}
if ! listening; then
  [ -f "$JAR" ] || { echo "server jar not found: $JAR"; exit 1; }
  mkdir -p "$DIR"; cp -n "$JAR" "$DIR/server.jar" 2>/dev/null || true
  echo "eula=true" > "$DIR/eula.txt"
  printf '%s\n' online-mode=false server-port=$PORT 'level-type=minecraft\:flat' view-distance=2 simulation-distance=2 network-compression-threshold=-1 \
    spawn-protection=0 enable-rcon=false enable-query=false motd=vanilla-int max-players=10 gamemode=creative difficulty=peaceful spawn-monsters=false \
    spawn-animals=false spawn-npcs=false generate-structures=false level-name=world white-list=false enforce-whitelist=false > "$DIR/server.properties"
  (cd "$DIR" && nohup "$JAVA" -Xmx1G -jar server.jar nogui > server.log 2>&1 &)
  for i in $(seq 1 90); do grep -q "Done (" "$DIR/server.log" 2>/dev/null && break; sleep 1; done
fi
python3 tools/capture_vanilla.py --port $PORT --seconds 3 --name Probe --out "$E2E/vanilla_join.jsonl" > /dev/null
python3 tools/capture_vanilla.py --port $PORT --seconds 3 --name Probe --out "$E2E/vanilla_join_returning.jsonl" > /dev/null   # a returning player: the burst dbcraft emulates
python3 tests/e2e/block_probe.py --port $PORT --out "$E2E/vanilla_block" --actor Acta --observer Bert > /dev/null
python3 tests/e2e/move_probe.py --port $PORT --name Walker --steps 6 --out "$E2E/vanilla_move6" > /dev/null
python3 tests/e2e/join_probe.py --port $PORT --out "$E2E/vanilla_social" --first Opa --second Bobb > /dev/null
echo "recorded the vanilla baselines in $E2E"
