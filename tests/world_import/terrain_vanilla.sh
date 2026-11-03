#!/usr/bin/env bash
# Does the REAL vanilla server read the terrain dbcraft:noise generates the way the database holds it?  Generates a square of noise terrain, exports it
# (tools/world_export.py), starts vanilla 26.3 on the export and asks it `execute if block X Y Z STATE` for sampled positions (tests/world_import/verify_export.py).  The area compared is RADIUS chunks around the origin; two more rings are exported.
# This checks the stored sections (palette, packed longs, counts that vanilla recomputes) by an implementation that is not ours; it says nothing about the terrain being
# vanilla's (it is not) or about the chunk packet (tests/sql/210 and 855 decode that).
#   tests/world_import/terrain_vanilla.sh [RADIUS_IN_CHUNKS]       libpq environment (PGHOST/PGPORT/PGUSER/PGDATABASE) selects a migrated database with the reference data
# env: WORK (default /dev/shm/dbcraft-terrain-vanilla: scratch, a few tens of MB), JAVA (Java 25), SERVER_JAR (default $DBCRAFT_HOME/server-26.3.jar), SAMPLES (default 800)
# WARNING: it replaces the overworld chunks of the database it is pointed at and leaves dbcraft.generator at dbcraft:noise.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/env.sh
R=${1:-8}; W=$((R + 2)); WORK=${WORK:-/dev/shm/dbcraft-terrain-vanilla}; JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-amd64/bin/java}
SERVER_JAR=${SERVER_JAR:-$DBCRAFT_SERVER_JAR}; SAMPLES=${SAMPLES:-800}
export RCON_PORT=25718 RCON_PW=importtest
rm -rf "$WORK"; mkdir -p "$WORK/srv"
psql -X -q -v ON_ERROR_STOP=1 <<SQL
update mc.server_property set value = 'dbcraft:noise' where key = 'dbcraft.generator';
delete from mc.chunk where dimension = 'minecraft:overworld';
select mc.pregenerate('minecraft:overworld', 0, 0, $W, true);
SQL
echo "generated $(psql -X -q -At -c "select count(*) from mc.chunk where dimension = 'minecraft:overworld'") chunks of noise terrain, seed $(psql -X -q -At -c "select seed from mc.world where name = 'world'")"
python3 tools/world_export.py "$WORK/srv/world" --box -$W -$W $W $W | tail -1
python3 tests/world_import/verify_export.py prepare "$WORK/samples.json" --samples "$((SAMPLES * 289 / ((2 * R + 1) * (2 * R + 1)) * 2))" --edits 0
# Vanilla fills in what is missing around an exported area: it generates the neighbours of the outermost chunks, and their decoration (ores) spills into chunks that are
# already complete.  So the world is exported two rings wider than the area that is sampled (the outer rings may differ; the inner square may not).
python3 - "$WORK/samples.json" "$R" "$SAMPLES" <<'PY'
import json, sys
p, r, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = json.load(open(p))
d["samples"] = [s for s in d["samples"] if abs(s[0] >> 4) <= r and abs(s[2] >> 4) <= r][:n]
json.dump(d, open(p, "w"))
print("kept %d samples inside the %d x %d chunks that are compared" % (len(d["samples"]), 2 * r + 1, 2 * r + 1))
PY
ln -sfn "$DBCRAFT_HOME/vanilla/libraries" "$WORK/srv/libraries"; ln -sfn "$DBCRAFT_HOME/vanilla/versions" "$WORK/srv/versions"
echo "eula=true" > "$WORK/srv/eula.txt"
printf '%s\n' online-mode=false server-port=25618 'level-type=minecraft\:flat' generate-structures=false view-distance=4 simulation-distance=2 enable-rcon=true rcon.port=25718 \
  rcon.password=importtest spawn-protection=0 gamemode=creative difficulty=peaceful spawn-monsters=false spawn-animals=false spawn-npcs=false white-list=false \
  enforce-whitelist=false max-tick-time=-1 pause-when-empty-seconds=-1 network-compression-threshold=-1 level-name=world max-players=2 > "$WORK/srv/server.properties"
cd "$WORK/srv"
nohup "$JAVA" -Xmx1G -jar "$SERVER_JAR" nogui > server.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
for i in $(seq 1 120); do grep -q "RCON running" server.log 2>/dev/null && break; sleep 1; done
grep -E "Done \(|ERROR|WARN.*(chunk|Chunk)" server.log | head -5 || true
cd - > /dev/null
python3 tests/world_import/verify_export.py check "$WORK/samples.json"
