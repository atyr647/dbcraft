#!/usr/bin/env bash
# Run the real vanilla Minecraft client under a virtual X display with software rendering, joining a server directly.
# usage: tools/realclient/run_client.sh start NAME HOST:PORT      start a client (username NAME) on display :99 (Xvfb is started if needed)
#        tools/realclient/run_client.sh stop NAME                  stop it
#        tools/realclient/run_client.sh log NAME                   print its log (latest.log of its game dir)
#        tools/realclient/run_client.sh shot NAME [FILE]           screenshot of the whole virtual screen (default /tmp/mc-client/shots/NAME-<time>.png)
# env: MC=/tmp/mc-client (the download_client.py output), DISPLAY_NUM=99, W=854 H=480, MEM=1G, JAVA25=/usr/lib/jvm/java-25-openjdk-amd64/bin/java
set -euo pipefail
MC=${MC:-/tmp/mc-client}; DN=${DISPLAY_NUM:-99}; W=${W:-854}; H=${H:-480}; MEM=${MEM:-1G}
JAVA=${JAVA25:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
export DISPLAY=:$DN
offline_uuid() {  # UUID v3 of "OfflinePlayer:<name>", the same value the servers compute
  python3 -I - "$1" <<'PY'
import hashlib, sys
h = bytearray(hashlib.md5(("OfflinePlayer:" + sys.argv[1]).encode()).digest()); h[6] = (h[6] & 0x0F) | 0x30; h[8] = (h[8] & 0x3F) | 0x80
x = h.hex(); print(f"{x[:8]}-{x[8:12]}-{x[12:16]}-{x[16:20]}-{x[20:]}")
PY
}
ensure_xvfb() {
  if ! xdpyinfo -display ":$DN" >/dev/null 2>&1; then
    (nohup Xvfb ":$DN" -screen 0 ${W}x${H}x24 -nolisten tcp > "$MC/xvfb.log" 2>&1 < /dev/null &)
    for i in $(seq 1 30); do xdpyinfo -display ":$DN" >/dev/null 2>&1 && break; sleep 0.2; done
  fi
}
case "${1:-}" in
  start)
    NAME=$2; ADDR=$3; GD="$MC/game-$NAME"; mkdir -p "$GD" "$MC/natives"
    ensure_xvfb
    # low-effort settings: 2 chunks, 20 fps, fast graphics, no narrator/tutorial/onboarding/multiplayer warning, muted
    cat > "$GD/options.txt" <<E
version:4800
renderDistance:2
simulationDistance:5
maxFps:20
graphicsMode:0
fancyGraphics:false
narrator:0
tutorialStep:none
onboardAccessibility:false
skipMultiplayerWarning:true
joinedFirstServer:true
pauseOnLostFocus:false
fullscreen:false
guiScale:2
soundCategory_master:0.0
chatColors:true
reducedDebugInfo:false
E
    CP=$(python3 -I -c "import json;print(':'.join(json.load(open('$MC/launch.json'))['classpath']))")
    IDX=$(python3 -I -c "import json;print(json.load(open('$MC/launch.json'))['assetIndex'])")
    UUID=$(offline_uuid "$NAME")
    cd "$GD"
    (env ${EXTRA_ENV:-SDL_VIDEO_FORCE_EGL=1 SDL_VIDEODRIVER=x11} LIBGL_ALWAYS_SOFTWARE=1 MESA_GL_VERSION_OVERRIDE=4.5 MESA_GLSL_VERSION_OVERRIDE=450 nohup "$JAVA" -Xmx$MEM -Xss1M -XX:StackShadowPages=32 --enable-native-access=ALL-UNNAMED \
      --add-exports java.base/jdk.internal.misc=ALL-UNNAMED \
      -Djava.library.path="$MC/natives/java" -Djna.tmpdir="$MC/natives/jna" -Dorg.lwjgl.system.SharedLibraryExtractPath="$MC/natives/lwjgl" -Dio.netty.native.workdir="$MC/natives/netty" \
      -Dminecraft.launcher.brand=dbcraft-test -Dminecraft.launcher.version=1 -cp "$CP" net.minecraft.client.main.Main \
      --username "$NAME" --version 26.3 --gameDir "$GD" --assetsDir "$MC/assets" --assetIndex "$IDX" --uuid "$UUID" --accessToken 0 --clientId 0 --xuid 0 \
      --versionType release --width $W --height $H --quickPlayPath "$GD/quickplay.json" --quickPlayMultiplayer "$ADDR" \
      > "$GD/stdout.log" 2>&1 < /dev/null & echo $! > "$GD/pid")
    echo "client $NAME started (pid $(cat "$GD/pid")), joining $ADDR; logs in $GD" ;;
  stop) GD="$MC/game-$2"; [ -f "$GD/pid" ] && kill "$(cat "$GD/pid")" 2>/dev/null || true; echo "client $2 stopped" ;;
  log) cat "$MC/game-$2/logs/latest.log" 2>/dev/null || cat "$MC/game-$2/stdout.log" ;;
  shot) mkdir -p "$MC/shots"; F=${3:-$MC/shots/$2-$(date +%H%M%S).png}; import -display ":$DN" -window root "$F"; echo "$F" ;;
  *) echo "usage: $0 start NAME HOST:PORT | stop NAME | log NAME | shot NAME [FILE]"; exit 2 ;;
esac
