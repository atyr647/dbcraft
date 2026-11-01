#!/usr/bin/env bash
# Start / stop the REAL vanilla 26.3 server as the reference for the real-client checks (offline mode, flat world, small view distance).
# usage: tools/realclient/vanilla_server.sh start|stop|log     env: VANILLA_DIR (default /tmp/vanilla-client), VANILLA_PORT (25613), VANILLA_JAR (/tmp/jar-dl/server.jar)
set -euo pipefail
DIR=${VANILLA_DIR:-/tmp/vanilla-client}; PORT=${VANILLA_PORT:-25613}; JAR=${VANILLA_JAR:-/tmp/jar-dl/server.jar}
JAVA=${JAVA25:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
case "${1:-}" in
  start)
    mkdir -p "$DIR"; cp -f "$JAR" "$DIR/server.jar"; echo "eula=true" > "$DIR/eula.txt"
    cat > "$DIR/server.properties" <<E
online-mode=false
server-port=$PORT
level-type=minecraft\:flat
view-distance=2
simulation-distance=2
network-compression-threshold=-1
spawn-protection=0
enable-rcon=false
motd=vanilla-reference
max-players=5
gamemode=creative
difficulty=peaceful
spawn-monsters=false
spawn-animals=false
spawn-npcs=false
generate-structures=false
white-list=false
enforce-whitelist=false
level-name=world
E
    cd "$DIR" && (nohup "$JAVA" -Xmx1G -jar server.jar nogui > server.log 2>&1 < /dev/null & echo $! > "$DIR/pid")
    for i in $(seq 1 60); do grep -q "Done (" "$DIR/server.log" 2>/dev/null && break; sleep 1; done
    grep "Done (" "$DIR/server.log" | cut -c1-90 ;;
  stop) [ -f "$DIR/pid" ] && kill "$(cat "$DIR/pid")" 2>/dev/null || true; echo stopped ;;
  log) cat "$DIR/server.log" ;;
  *) echo "usage: $0 start|stop|log"; exit 2 ;;
esac
