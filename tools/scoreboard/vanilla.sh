#!/usr/bin/env bash
# Start/stop the real vanilla 26.3 server for the scoreboard.   usage: vanilla.sh start [VIEW_DISTANCE] | stop | kill9 | status | reset
set -euo pipefail
D=/tmp/vanilla-score
JAVA=/usr/lib/jvm/java-25-openjdk-amd64/bin/java
pid() {
  for p in $(pgrep -f "server.jar nogui" || true); do
    if [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$D" ]; then echo "$p"; return; fi
  done
}
case "${1:-}" in
  start)
    VD=${2:-10}
    mkdir -p $D
    cd $D
    [ -f server.jar ] || cp /tmp/jar-dl/server.jar .
    echo "eula=true" > eula.txt
    cat > server.properties <<P
online-mode=false
server-port=25615
level-type=minecraft\:flat
view-distance=$VD
simulation-distance=10
network-compression-threshold=-1
spawn-protection=0
enable-rcon=true
rcon.port=25625
rcon.password=score
enable-query=false
motd=vanilla-score
max-players=1000
gamemode=creative
force-gamemode=true
difficulty=easy
spawn-monsters=false
spawn-animals=false
spawn-npcs=false
generate-structures=false
white-list=false
enforce-whitelist=false
level-name=world
player-idle-timeout=0
max-tick-time=-1
P
    : > server.log
    : > gc.log
    (nohup $JAVA -Xms2G -Xmx2G -Xlog:gc:file=$D/gc.log:uptime -jar server.jar nogui > server.log 2>&1 &)
    for i in $(seq 1 240); do
      if grep -q "Done (" server.log 2>/dev/null; then break; fi
      sleep 0.5
    done
    if ! grep -q "Done (" server.log; then echo "vanilla did not start"; tail -5 server.log; exit 1; fi
    echo "vanilla started pid $(pid), $(grep -o 'Done ([0-9.]*s)' server.log | tail -1)"
    ;;
  stop)
    p=$(pid || true)
    if [ -n "$p" ]; then
      kill "$p"
      for i in $(seq 1 120); do
        kill -0 "$p" 2>/dev/null || break
        sleep 0.5
      done
    fi
    echo stopped
    ;;
  kill9)
    p=$(pid || true)
    if [ -n "$p" ]; then kill -9 "$p"; fi
    sleep 1
    echo killed
    ;;
  status)
    p=$(pid || true)
    echo "pid=${p:-none}"
    ;;
  reset)
    "$0" stop
    rm -rf $D/world
    echo "world removed"
    ;;
  *)
    echo "usage: $0 start [VD] | stop | kill9 | status | reset"
    exit 2
    ;;
esac
