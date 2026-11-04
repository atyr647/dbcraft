#!/usr/bin/env bash
# One-command setup of dbcraft on Ubuntu 24.04.  Idempotent: every step checks its own result and is skipped when already done.
#
#   tools/bootstrap.sh [--check] [--no-apt] [--no-gateway] [--recapture] [--fresh-db] [--up]
#
#   --check        change nothing, report the state of every step (exit 1 when something is missing)
#   --no-apt       do not install packages (they are only checked)
#   --no-gateway   do not build the Rust gateway (the PL/Python development gateway is used instead)
#   --recapture    record the vanilla captures again
#   --fresh-db     rebuild the database from scratch
#   --up           start PostgreSQL and the gateway when done (tools/dev-up.sh)
#
# Steps: 1 packages  2 the pinned vanilla server jar (downloaded from Mojang, SHA-1 verified)  3 the official data generator -> reports  4 a recorded capture of a
# real vanilla server (for the datapack registries, tags and a few opaque packets)  5 the database  6 the Rust gateway.
# Everything Mojang-owned lands under $DBCRAFT_HOME (default ~/.cache/dbcraft) and is never committed.  See README.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. tools/env.sh

CHECK=0; APT=1; GATEWAY=1; RECAPTURE=0; FRESHDB=0; UP=0; DATA_ONLY=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;; --no-apt) APT=0 ;; --no-gateway) GATEWAY=0 ;; --recapture) RECAPTURE=1 ;; --fresh-db) FRESHDB=1 ;; --up) UP=1 ;;
    --data-only) DATA_ONLY=1; GATEWAY=0 ;;
    -h|--help) sed -n 2,16p "$0"; exit 0 ;;
    *) echo "unknown option $a (see --help)" >&2; exit 2 ;;
  esac
done
STARTED=$(date +%s); MISSING=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    ok       %s\n' "$*"; }
todo() { printf '    MISSING  %s\n' "$*"; MISSING=1; }
mkdir -p "$DBCRAFT_HOME" "$DBCRAFT_LOG" "$DBCRAFT_RUN"

# ------------------------------------------------------------------------------------------------------------------------------ 1. packages
say "1/6 packages (Ubuntu 24.04)"
PKGS="postgresql-16 libpq5 libpq-dev libssl-dev libcurl4t64 zlib1g-dev openjdk-25-jre-headless python3 curl unzip ca-certificates"
OPT_PKGS="postgresql-plpython3-16"       # only the PL/Python development gateway needs this one
if [ "$DATA_ONLY" = 1 ]; then PKGS="openjdk-25-jre-headless python3 ca-certificates"; OPT_PKGS="python3"; fi   # the Docker data service: jar, reports and captures only
missing=""; for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
if [ -z "$missing" ]; then ok "required packages installed"; else
  if [ "$CHECK" = 1 ] || [ "$APT" = 0 ]; then todo "packages:$missing"; else
    SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"
    echo "    installing:$missing"
    $SUDO apt-get install -y $missing >"$DBCRAFT_LOG/apt.log" 2>&1 || { $SUDO apt-get update >>"$DBCRAFT_LOG/apt.log" 2>&1; $SUDO apt-get install -y $missing >>"$DBCRAFT_LOG/apt.log" 2>&1; } \
      || { echo "apt-get failed, see $DBCRAFT_LOG/apt.log"; exit 1; }
    ok "installed"
  fi
fi
if dpkg -s $OPT_PKGS >/dev/null 2>&1; then ok "postgresql-plpython3-16 (optional, development gateway)"; elif [ "$CHECK" = 0 ] && [ "$APT" = 1 ]; then
  ( SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"; $SUDO apt-get install -y $OPT_PKGS >>"$DBCRAFT_LOG/apt.log" 2>&1 ) && ok "installed postgresql-plpython3-16 (optional)" \
    || echo "    note     postgresql-plpython3-16 not installed: only the Rust gateway will be available"
else echo "    note     postgresql-plpython3-16 missing (optional: the PL/Python development gateway)"; fi
if command -v rustc >/dev/null 2>&1; then ok "rustc $(rustc --version | cut -d' ' -f2) (gateway)"; elif [ "$GATEWAY" = 1 ]; then
  if [ "$CHECK" = 1 ] || [ "$APT" = 0 ]; then todo "rustc (apt install rustc, or --no-gateway)"; else
    SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"; $SUDO apt-get install -y rustc >>"$DBCRAFT_LOG/apt.log" 2>&1 && ok "installed rustc" || todo "rustc could not be installed (use --no-gateway)"; fi
fi
. tools/env.sh        # pick up a freshly installed Java 25
if [ -n "$JAVA" ]; then ok "Java 25 at $JAVA"; else todo "Java 25 not found (openjdk-25-jre-headless)"; fi

# ------------------------------------------------------------------------------------------------------------------------------ 2. server jar
say "2/6 vanilla server jar (Mojang, pinned: 26.3, SHA-1 33680f5f...)"
if [ "$CHECK" = 1 ]; then
  if [ -f "$DBCRAFT_SERVER_JAR" ] && [ "$(sha1sum "$DBCRAFT_SERVER_JAR" | cut -d' ' -f1)" = 33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c ]; then ok "$DBCRAFT_SERVER_JAR verified"; else todo "server jar ($DBCRAFT_SERVER_JAR)"; fi
else
  python3 tools/fetch_jar.py "$DBCRAFT_SERVER_JAR"
fi

# ------------------------------------------------------------------------------------------------------------------------------ 3. generator reports
say "3/6 data generator reports (the official generator, run from the jar)"
want=""; [ -f "$DBCRAFT_SERVER_JAR" ] && want=$(sha1sum "$DBCRAFT_SERVER_JAR" | cut -d' ' -f1)
have_reports() { [ -f "$DBCRAFT_REPORTS/blocks.json" ] && [ -f "$DBCRAFT_REPORTS/packets.json" ] && [ -f "$DBCRAFT_REPORTS/registries.json" ] && [ "$(cat "$DBCRAFT_REPORTS/.jar-sha1" 2>/dev/null)" = "$want" ]; }
if have_reports; then ok "reports in $DBCRAFT_REPORTS"; elif [ "$CHECK" = 1 ]; then todo "reports ($DBCRAFT_REPORTS)"; else
  [ -n "$JAVA" ] || { echo "Java 25 is needed to run the generator"; exit 1; }
  work="$DBCRAFT_HOME/work"; rm -rf "$work"; mkdir -p "$work"
  echo "    running the generator (about 15 s) ..."
  ( cd "$work" && "$JAVA" -DbundlerMainClass=net.minecraft.data.Main -jar "$DBCRAFT_SERVER_JAR" --reports --output gen ) >"$DBCRAFT_LOG/generator.log" 2>&1 \
    || { echo "generator failed, see $DBCRAFT_LOG/generator.log"; exit 1; }
  mkdir -p "$DBCRAFT_REPORTS"
  for f in blocks registries packets commands datapack; do cp "$work/gen/reports/$f.json" "$DBCRAFT_REPORTS/$f.json"; done
  rm -rf "$DBCRAFT_REPORTS/item_components"; cp -r "$work/gen/reports/minecraft/components/item" "$DBCRAFT_REPORTS/item_components"      # per-item components (tools/load_item_components.py)
  echo "$want" > "$DBCRAFT_REPORTS/.jar-sha1"; rm -rf "$work"
  ok "reports written to $DBCRAFT_REPORTS"
fi
# the per-item component reports came later than the other reports: a cache made before them gets them from a second generator run
have_items() { [ -s "$DBCRAFT_REPORTS/item_components/iron_sword.json" ]; }
if have_items; then ok "item components in $DBCRAFT_REPORTS/item_components"; elif [ "$CHECK" = 1 ]; then todo "item components ($DBCRAFT_REPORTS/item_components)"; else
  [ -n "$JAVA" ] || { echo "Java 25 is needed to run the generator"; exit 1; }
  work="$DBCRAFT_HOME/work"; rm -rf "$work"; mkdir -p "$work"
  ( cd "$work" && "$JAVA" -DbundlerMainClass=net.minecraft.data.Main -jar "$DBCRAFT_SERVER_JAR" --reports --output gen ) >"$DBCRAFT_LOG/generator.log" 2>&1 \
    || { echo "generator failed, see $DBCRAFT_LOG/generator.log"; exit 1; }
  rm -rf "$DBCRAFT_REPORTS/item_components"; cp -r "$work/gen/reports/minecraft/components/item" "$DBCRAFT_REPORTS/item_components"; rm -rf "$work"
  ok "item components written to $DBCRAFT_REPORTS/item_components"
fi

# ------------------------------------------------------------------------------------------------------------------------------ 4. captures
say "4/6 recorded capture of a real vanilla server (configuration data the database replays)"
have_caps() { [ -s "$DBCRAFT_CAPTURES/play_nocomp.jsonl" ]; }
if have_caps && [ "$RECAPTURE" = 0 ]; then ok "captures in $DBCRAFT_CAPTURES"; elif [ "$CHECK" = 1 ]; then todo "captures ($DBCRAFT_CAPTURES)"; else
  have_reports || { echo "the reports are needed to record captures"; exit 1; }
  VPORT=${DBCRAFT_VANILLA_PORT:-25619}; VDIR="$DBCRAFT_HOME/vanilla"
  rm -rf "$VDIR"; mkdir -p "$VDIR" "$DBCRAFT_CAPTURES"
  echo "eula=true" > "$VDIR/eula.txt"      # Mojang's EULA: by running the server you accept it (https://aka.ms/MinecraftEULA)
  vprops() {   # $1 = view distance.  The tests expect this MOTD and 5 slots (tests/sql/110): do not change them.
    cat > "$VDIR/server.properties" <<EOF
online-mode=false
server-port=$VPORT
level-type=minecraft\:flat
view-distance=$1
simulation-distance=2
network-compression-threshold=-1
spawn-protection=0
enable-rcon=false
enable-query=false
motd=vanilla-oracle
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
EOF
  }
  cleanup_vanilla() {
    [ -f "$VDIR/server.pid" ] || return 0
    local pid; pid=$(cat "$VDIR/server.pid"); kill "$pid" 2>/dev/null || return 0     # SIGTERM: the server saves the world, then exits
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null || true       # only for a hung shutdown
  }
  vstart() {   # $1 = view distance
    vprops "$1"; : > "$VDIR/server.log"
    # (cd; then the background command: `cd && cmd &` would background the whole list and $! would be the subshell, not Java)
    ( cd "$VDIR"; nohup "$JAVA" -Xmx1G -jar "$DBCRAFT_SERVER_JAR" nogui >server.log 2>&1 & echo $! > "$VDIR/server.pid" )
    for _ in $(seq 1 120); do grep -q "Done (" "$VDIR/server.log" 2>/dev/null && break; sleep 1; done
    grep -q "Done (" "$VDIR/server.log" || { echo "vanilla server did not start, see $VDIR/server.log"; exit 1; }
  }
  trap cleanup_vanilla EXIT
  # success = the recording exists: the bot exits non-zero when vanilla refuses it on purpose (an invalid name, a bad teleport), and that refusal IS the recording
  rec() { name=$1; shift; rm -f "$DBCRAFT_CAPTURES/$name.jsonl"
          python3 tools/capture_vanilla.py --port "$VPORT" --out "$DBCRAFT_CAPTURES/$name.jsonl" "$@" >"$DBCRAFT_LOG/capture-$name.log" 2>&1 || true
          if [ -s "$DBCRAFT_CAPTURES/$name.jsonl" ]; then echo "    recorded $name ($(wc -l < "$DBCRAFT_CAPTURES/$name.jsonl") packets)"
          else echo "    note     capture $name failed (see $DBCRAFT_LOG/capture-$name.log): tests that need it will skip"; fi; }
  # On a brand-new world vanilla's light engine has not finished with the chunks around the spawn when they are first sent, and the chunks on the edge of the loaded
  # area are lit without their neighbours: a first-login capture holds different light data than a steady-state one (tests/sql/240 compares dbcraft with the
  # steady state).  So: phase 1 loads and lights a large area (view distance 8) with two throwaway logins and saves it; phase 2 restarts the SAME world with view
  # distance 2, so every chunk of the capture is loaded from disk, fully lit.
  echo "    phase 1/2: a throwaway vanilla server (port $VPORT, view distance 8) generates and lights the area around the spawn ..."
  vstart 8
  for w in 1 2; do python3 tools/capture_vanilla.py --port "$VPORT" --out "$DBCRAFT_LOG/warmup-$w.jsonl" --seconds 8 >/dev/null 2>&1 || true; done
  cleanup_vanilla; sleep 1
  echo "    phase 2/2: the same world, view distance 2: recording ..."
  vstart 2
  rec status --status          # first: nobody has connected yet, so the response says 0 players online (tests/sql/110 expects that; right after a login the bot is still being dropped)
  rec play_nocomp --seconds 8
  [ -s "$DBCRAFT_CAPTURES/play_nocomp.jsonl" ] || { echo "the main capture failed"; exit 1; }
  rec play --seconds 6
  rec badname --name "has space"
  rec play_known --known-core --seconds 4
  rec play_disconnect --bad-teleport --seconds 4
  cleanup_vanilla; trap - EXIT; sleep 2
  ok "captures written to $DBCRAFT_CAPTURES"
fi

# ------------------------------------------------------------------------------------------------------------------------------ 5. database
say "5/6 database (PostgreSQL development cluster in $DBCRAFT_PGDATA, port $DBCRAFT_PGPORT)"
if [ "$DATA_ONLY" = 1 ]; then echo "    skipped (--data-only)"
elif [ "$CHECK" = 1 ]; then
  if psql -X -h /tmp -p "$DBCRAFT_PGPORT" -U postgres dbcraft -At -c "select count(*) from ref.block_state" 2>/dev/null | grep -q 35723; then ok "database dbcraft is loaded"; else todo "database (run without --check)"; fi
else
  tools/setup-db.sh $([ "$FRESHDB" = 1 ] && echo --fresh)
fi

# ------------------------------------------------------------------------------------------------------------------------------ 6. gateway
say "6/6 Rust gateway (gateway/build.sh, plain rustc, no crates)"
if [ "$GATEWAY" = 0 ]; then echo "    skipped (--no-gateway): the PL/Python development gateway will be used"
elif [ "$CHECK" = 1 ]; then
  if [ -x gateway/target/dbcraft-gateway ]; then ok "gateway/target/dbcraft-gateway"; else todo "gateway binary (run without --check)"; fi
else
  if command -v rustc >/dev/null 2>&1; then gateway/build.sh >"$DBCRAFT_LOG/gateway-build.log" 2>&1 && ok "built gateway/target/dbcraft-gateway" \
    || { echo "    note     gateway build failed (see $DBCRAFT_LOG/gateway-build.log): the PL/Python development gateway will be used"; }
  else echo "    note     no rustc: the PL/Python development gateway will be used"; fi
fi

say "done in $(( $(date +%s) - STARTED )) s"
if [ "$CHECK" = 1 ]; then [ "$MISSING" = 0 ] && echo "everything is in place" || { echo "something is missing: run tools/bootstrap.sh"; exit 1; }; exit 0; fi
if [ "$DATA_ONLY" = 1 ]; then echo "Mojang data is ready under $DBCRAFT_HOME"; exit 0; fi
if [ "$UP" = 1 ]; then tools/dev-up.sh; else echo "start the server with:  tools/dev-up.sh   (or: make up)"; fi
