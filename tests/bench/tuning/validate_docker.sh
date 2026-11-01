#!/usr/bin/env bash
# Validate the container pieces without a Docker daemon (there is none in the environment this was written in):
#   1. `bash -n` on the entrypoint scripts
#   2. a REAL PostgreSQL cluster started with docker/postgresql.conf exactly as the image starts it (-c config_file=...)
#   3. docker/initdb.d/10-dbcraft.sh run against that cluster with the environment variables the image sets (schema, reports, datapack, dev-gateway settings)
#   4. the settings that matter read back from the running server and from the database (sql/450_tuning.sql)
#   5. a short tick loop (tests/bench/tuning/steady_top.py) against it
# usage: tests/bench/tuning/validate_docker.sh        env: VD_DATA (default /tmp/dbcraft-pg-tune-vd), VD_PORT (default 54481), DBCRAFT_REPORTS, DBCRAFT_CAPTURES
set -euo pipefail
cd "$(dirname "$0")/../../.."
DATA=${VD_DATA:-/tmp/dbcraft-pg-tune-vd}; PORT=${VD_PORT:-54481}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
for f in docker/entrypoint.sh docker/initdb.d/10-dbcraft.sh tools/janitor.sh; do bash -n "$f" && echo "ok: bash -n $f"; done
as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$DATA"; mkdir -p "$DATA"; [ "$(id -u)" = 0 ] && chown postgres "$DATA"
as_pg "$PGBIN/initdb -D $DATA -A trust -E UTF8 >/dev/null"
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
# the image starts: postgres -c config_file=/etc/dbcraft/postgresql.conf   (the data directory comes from PGDATA; the port and socket directory are overridden here)
as_pg "ulimit -n 20000; $PGBIN/pg_ctl -D $DATA -o '-c config_file=$PWD/docker/postgresql.conf -p $PORT -k /tmp' -l $DATA/log -w start" >/dev/null
echo "ok: PostgreSQL started with docker/postgresql.conf"
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=postgres
psql -X -q -c "create database dbcraft" >/dev/null
export PGDATABASE=dbcraft POSTGRES_USER=postgres POSTGRES_DB=dbcraft DBCRAFT_HOME=$PWD DBCRAFT_DEV_GATEWAY=1 DBCRAFT_MOTD=dbcraft DBCRAFT_GAMEMODE=survival
export DBCRAFT_REPORTS=${DBCRAFT_REPORTS:-/home/user/atyr647/adacraft/generated/26.3/reports} DBCRAFT_CAPTURES=${DBCRAFT_CAPTURES:-/home/user/dbcraft/tests/fixtures/captured}
bash docker/initdb.d/10-dbcraft.sh 2>&1 | grep -v NOTICE | tail -5
echo "--- settings as the running server reports them:"
psql -X -At -F ' = ' -c "select name, current_setting(name) from pg_settings where name in ('shared_buffers','work_mem','fsync','synchronous_commit','jit','max_parallel_workers_per_gather','autovacuum_naptime','checkpoint_timeout','max_wal_size','idle_in_transaction_session_timeout','wal_level','full_page_writes','wal_compression','random_page_cost') order by name"
echo "--- database-level defaults stored by sql/450_tuning.sql:"
psql -X -At -c "select unnest(setconfig) from pg_db_role_setting where setdatabase = (select oid from pg_database where datname = 'dbcraft') order by 1"
echo "--- a short tick loop against it:"
psql -X -q -At -f tests/bench/integration/bench.sql -f tests/bench/tuning/steady.sql >/dev/null 2>&1
psql -X -q -At -c "select ibench.setup(100, 20)" -c "select mc.refresh_visibility()" -c "analyze" >/dev/null
python3 tests/bench/tuning/steady_top.py --ticks 100 --frac 0.25 --csv /tmp/dbcraft-vd-lat.csv
python3 - <<'PY'
import csv
rows = [r.split(",") for r in open("/tmp/dbcraft-vd-lat.csv")]
lat = sorted(float(r[7]) for r in rows)
print(f"ok: {len(lat)} ticks, median {lat[len(lat)//2]:.1f} ms, max {lat[-1]:.1f} ms (100 players, 25% moving)")
PY
rm -f /tmp/dbcraft-vd-lat.csv
