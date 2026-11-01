#!/usr/bin/env bash
# Start/stop one benchmark cluster per PostgreSQL build variant, all with IDENTICAL settings, each on its own port and data directory.
#   usage: tools/pgbuild/cluster.sh VARIANT start|stop|status|psql|env
#   A  the distro binary (/usr/lib/postgresql/16/bin)        port 54501   data /tmp/pg-data-A
#   B  plain -O2 build   (/tmp/pg-runtime-B)                  port 54502   data /tmp/pg-data-B
#   C  -O3 -march=native + LTO (/tmp/pg-runtime-C)            port 54503   data /tmp/pg-data-C
#   D  C + PGO (/tmp/pg-runtime-D2)                           port 54504   data /tmp/pg-data-D
#   G  the instrumented PGO training build (/tmp/pg-runtime-D1) port 54505 data /tmp/pg-data-G
# (the 5450x range: other jobs on this machine use 54329, 54399, 54411/12/21, 54466, 54477, 54488)
# Same data directory contents for every variant (they are copies of one warmed base: tools/pgbuild/setup_base.sh), same flags below.
set -euo pipefail
V=${1:?variant A|B|C|D|G}
CMD=${2:-status}
case "$V" in
  A) BIN=/usr/lib/postgresql/16/bin; PORT=54501 ;;
  B) BIN=/tmp/pg-runtime-B/bin;      PORT=54502 ;;
  C) BIN=/tmp/pg-runtime-C/bin;      PORT=54503 ;;
  D) BIN=/tmp/pg-runtime-D2/bin;     PORT=54504 ;;
  G) BIN=/tmp/pg-runtime-D1/bin;     PORT=54505 ;;
  *) echo "unknown variant $V"; exit 2 ;;
esac
DATA=/tmp/pg-data-$V
FLAGS="-p $PORT -k /tmp -c listen_addresses= -c fsync=off -c synchronous_commit=off -c max_connections=100 -c shared_buffers=256MB -c jit=off -c autovacuum_naptime=1s -c huge_pages=${PG_HUGE_PAGES:-try}"
case "$CMD" in
  start)  su postgres -s /bin/bash -c "ulimit -n 20000; $BIN/pg_ctl -D $DATA -o '$FLAGS' -l $DATA/log -w start" >/dev/null ;;
  stop)   su postgres -s /bin/bash -c "$BIN/pg_ctl -D $DATA -m fast stop" >/dev/null ;;
  status) su postgres -s /bin/bash -c "$BIN/pg_ctl -D $DATA status" | head -1 ;;
  psql)   shift 2; exec psql -X -h /tmp -p "$PORT" -U postgres dbcraft "$@" ;;
  env)    echo "export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=dbcraft DBCRAFT_PGPORT=$PORT DBCRAFT_PGDATA=$DATA DBCRAFT_PGBIN=$BIN" ;;
  *) echo "usage: $0 VARIANT start|stop|status|psql|env"; exit 2 ;;
esac
