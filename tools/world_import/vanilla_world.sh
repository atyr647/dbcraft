#!/usr/bin/env bash
# Generates a real vanilla 26.3 world for the importer tests, in /tmp/vanilla-import (never committed: it is Mojang data).
#   tools/world_import/vanilla_world.sh start      start the vanilla server (offline, fixed seed, RCON on 25718)
#   tools/world_import/vanilla_world.sh stop       save and stop it cleanly (so every region file is complete)
#   tools/world_import/vanilla_world.sh cmd '...'  run one command over RCON
# Needs: /tmp/jar-dl/server.jar (the official 26.3 server.jar, SHA-1 33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c) and Java 25.
set -euo pipefail
D=${VANILLA_IMPORT_DIR:-/tmp/vanilla-import}
JAVA=${JAVA25:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
export RCON_PORT=25718 RCON_PW=importtest
case "${1:-}" in
  start)
    mkdir -p "$D"; cp -n /tmp/jar-dl/server.jar "$D/server.jar" 2>/dev/null || true
    echo "eula=true" > "$D/eula.txt"
    cat > "$D/server.properties" <<'E'
online-mode=false
server-port=25618
level-seed=dbcraft-import-7
level-type=minecraft\:normal
generate-structures=true
view-distance=8
simulation-distance=3
enable-rcon=true
rcon.port=25718
rcon.password=importtest
spawn-protection=0
gamemode=creative
difficulty=peaceful
spawn-monsters=false
spawn-animals=false
spawn-npcs=false
white-list=false
enforce-whitelist=false
max-tick-time=-1
pause-when-empty-seconds=-1
network-compression-threshold=-1
motd=vanilla-import
max-players=5
level-name=world
E
    cd "$D"
    nohup "$JAVA" -Xmx2G -jar server.jar nogui > server.log 2>&1 &
    for i in $(seq 1 120); do grep -q "Done (" server.log 2>/dev/null && break; sleep 2; done
    grep -E "Done \(" server.log | head -1
    ;;
  cmd)
    python3 "$HERE/tools/entity/rcon.py" cmd "$2"
    ;;
  reset)
    # restore the generated world from the pristine copy and drop the force-load tickets, so a capture sees exactly what is on disk
    # (force-loaded chunks tick: grass breaks, water flows, ... and a comparison with the files would show vanilla's simulation, not the import)
    rm -rf "$D/world"
    cp -r "$D/world.pristine" "$D/world"
    rm -f "$D/world/dimensions/minecraft/overworld/data/minecraft/chunk_tickets.dat"
    echo "world restored from $D/world.pristine"
    ;;
  stop)
    python3 "$HERE/tools/entity/rcon.py" cmd "save-all flush" || true
    python3 "$HERE/tools/entity/rcon.py" cmd "stop" || true
    for i in $(seq 1 60); do pgrep -f "[j]ava.*vanilla-import|[s]erver.jar nogui" >/dev/null || break; sleep 1; done
    echo stopped
    ;;
  *) echo "usage: $0 start|stop|cmd 'command'"; exit 2 ;;
esac
