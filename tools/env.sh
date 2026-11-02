# Source me:   . tools/env.sh      Locations used by every dbcraft tool.  Everything is overridable by setting the variable first.
# Nothing here lives inside the repository: Mojang data (the server jar, generator reports, recorded captures) is derived on YOUR machine by tools/bootstrap.sh
# and kept under $DBCRAFT_HOME, never committed.
DBCRAFT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
export DBCRAFT_ROOT
export DBCRAFT_HOME=${DBCRAFT_HOME:-$HOME/.cache/dbcraft}
export DBCRAFT_REPORTS=${DBCRAFT_REPORTS:-$DBCRAFT_HOME/reports}          # blocks.json, registries.json, packets.json ... from the official data generator
export DBCRAFT_CAPTURES=${DBCRAFT_CAPTURES:-$DBCRAFT_HOME/captures}       # packet recordings of a real vanilla server (tools/capture_vanilla.py)
export DBCRAFT_SERVER_JAR=${DBCRAFT_SERVER_JAR:-$DBCRAFT_HOME/server-26.3.jar}
export DBCRAFT_CORPUS=${DBCRAFT_CORPUS:-$DBCRAFT_ROOT/tests/corpus}       # adacraft's byte-exact handshake/status/login scenarios (copied into this repository)
if [ -z "${JAVA:-}" ]; then
  for j in /usr/lib/jvm/java-25-openjdk-amd64/bin/java /usr/lib/jvm/java-25*/bin/java "$(command -v java 2>/dev/null)"; do
    if [ -x "$j" ] && "$j" -version 2>&1 | grep -q 'version "2[5-9]'; then JAVA=$j; break; fi
  done
fi
export JAVA=${JAVA:-}
# The development PostgreSQL cluster (tools/pg-dev.sh).  As root it runs as the postgres OS user, which cannot read root's home, so its data goes to /var/lib.
if [ -z "${DBCRAFT_PGDATA:-}" ]; then
  if [ "$(id -u)" = 0 ]; then DBCRAFT_PGDATA=/var/lib/dbcraft/pg; else DBCRAFT_PGDATA=$DBCRAFT_HOME/pg; fi
fi
export DBCRAFT_PGDATA
export DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54329}
export DBCRAFT_PORT=${DBCRAFT_PORT:-25565}                                # the Minecraft port the gateway listens on
export DBCRAFT_LOG=${DBCRAFT_LOG:-$DBCRAFT_HOME/log} DBCRAFT_RUN=${DBCRAFT_RUN:-$DBCRAFT_HOME/run}   # logs and pid files of tools/dev-up.sh
