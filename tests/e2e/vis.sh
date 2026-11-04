#!/usr/bin/env bash
# The player-visibility comparison (docs/PLAYER-VISIBILITY.md): record the REAL vanilla server (once), replay the same scripted clients against dbcraft over TCP, compare.
#
#   tests/e2e/vis.sh vanilla-start          (re)start a vanilla 26.3 server with a FRESH world (flat, survival, normal, no mobs, view distance 3) in $VIS_VDIR
#   tests/e2e/vis.sh record [SCENARIO...]   per scenario: fresh vanilla world, probe both clients, write $VIS_DIR/vanilla_<scenario>_*.jsonl
#   tests/e2e/vis.sh compare PORT [SCENARIO...]
#                                           against a running dbcraft server (dev gateway or the Rust gateway: survival, flat, view distance 3, no entities); PGHOST/PGPORT/PGDATABASE name its
#                                           database (the probe makes "Act" an operator there; `compare` also deletes the probe players first so every run joins them for the first time)
# environment: VIS_DIR (recordings, default /tmp/dbcraft-e2e-vis), VIS_VDIR (the vanilla server directory), VIS_VPORT / VIS_RCON (default 25841 / 25845), DBCRAFT_SERVER_JAR, JAVA
# Recordings contain Mojang data and are never committed.
set -uo pipefail
cd "$(dirname "$0")/../.."
VIS_DIR=${VIS_DIR:-/tmp/dbcraft-e2e-vis}; VIS_VDIR=${VIS_VDIR:-/tmp/dbcraft-vis-vanilla}; VPORT=${VIS_VPORT:-25841}; RCON=${VIS_RCON:-25845}
JAR=${DBCRAFT_SERVER_JAR:-${DBCRAFT_HOME:-$HOME/.cache/dbcraft}/server-26.3.jar}; JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
SCENARIOS="join pose walk latency range view"
mkdir -p "$VIS_DIR"

listening() { python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); s.connect(('127.0.0.1',int(sys.argv[1])))" "$1" 2>/dev/null; }

vanilla_start() {
  if listening "$VPORT"; then
    python3 - "$RCON" <<'PY' 2>/dev/null
import sys; sys.path.insert(0, "tools/scoreboard")
import common as C
C.Rcon(port=int(sys.argv[1]), pw="dbcraft-e2e").cmd("stop")
PY
    for i in $(seq 1 40); do listening "$VPORT" || break; sleep 0.5; done
  fi
  # the old server saves the world after it stops listening: wait for the process itself (a loaded machine takes seconds), or the new world is deleted under it
  vdir=$(readlink -f "$VIS_VDIR" 2>/dev/null || echo "$VIS_VDIR")
  for i in $(seq 1 120); do
    busy=0; for d in /proc/[0-9]*/cwd; do [ "$(readlink "$d" 2>/dev/null)" = "$vdir" ] && busy=1 && break; done
    [ $busy = 0 ] && break; sleep 0.5
  done
  mkdir -p "$VIS_VDIR"; cp -n "$JAR" "$VIS_VDIR/server.jar" 2>/dev/null || true
  rm -rf "$VIS_VDIR/world" "$VIS_VDIR/usercache.json" "$VIS_VDIR/ops.json"
  echo "eula=true" > "$VIS_VDIR/eula.txt"
  printf '%s\n' online-mode=false server-port=$VPORT 'level-type=minecraft\:flat' view-distance=3 simulation-distance=3 network-compression-threshold=-1 spawn-protection=0 \
    enable-rcon=true rcon.port=$RCON rcon.password=dbcraft-e2e motd=vis max-players=10 gamemode=survival difficulty=normal spawn-monsters=false spawn-animals=false spawn-npcs=false \
    generate-structures=false level-name=world white-list=false enforce-whitelist=false > "$VIS_VDIR/server.properties"
  (cd "$VIS_VDIR" && nohup "$JAVA" -Xmx1G -jar server.jar nogui > server.log 2>&1 &)
  for i in $(seq 1 240); do grep -q "Done (" "$VIS_VDIR/server.log" 2>/dev/null && listening "$RCON" && break; sleep 0.5; done
  python3 - "$RCON" <<'PY'
import sys; sys.path.insert(0, "tools/scoreboard")
import common as C
r = C.Rcon(port=int(sys.argv[1]), pw="dbcraft-e2e")
for c in ("gamerule spawn_mobs false", "gamerule spawn_monsters false", "gamerule spawn_patrols false", "gamerule spawn_wandering_traders false", "gamerule spawn_phantoms false",
          "kill @e[type=!player]"):
    r.cmd(c)
PY
}

case "${1:-}" in
  vanilla-start) vanilla_start ;;
  record)
    shift; for s in ${@:-$SCENARIOS}; do
      vanilla_start; python3 tests/e2e/vis_probe.py "$s" --port "$VPORT" --rcon "$RCON" --out "$VIS_DIR/vanilla" | tail -1
    done ;;
  compare)
    P=${2:?dbcraft port}; shift 2; rc=0
    PSQL="psql -X -At"
    for s in ${@:-$SCENARIOS}; do
      $PSQL -c "delete from mc.player where name in ('Act', 'Obs') and conn_id is null" > /dev/null 2>&1
      python3 tests/e2e/vis_probe.py "$s" --port "$P" --psql "$PSQL" --out "$VIS_DIR/ours" > /dev/null || rc=1
      python3 tests/e2e/compare_vis.py "$s" "$VIS_DIR/vanilla" "$VIS_DIR/ours" || rc=1
    done
    [ $rc = 0 ] && echo "ALL VISIBILITY COMPARISONS PASSED" || echo "SOME VISIBILITY COMPARISONS FAILED"; exit $rc ;;
  *) echo "usage: $0 vanilla-start | record [SCENARIO...] | compare DBCRAFT_PORT [SCENARIO...]"; exit 2 ;;
esac
