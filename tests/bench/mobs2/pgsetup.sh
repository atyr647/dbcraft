#!/usr/bin/env bash
# the benchmark configuration of docs/WHY-MOBS-COST.md for a cluster made by tests/bench/entity/setup_db.sh: pg_stat_statements (track all, planning), function statistics, jit off, the docker settings
# usage: DBCRAFT_PGDATA=... DBCRAFT_PGPORT=... tests/bench/mobs2/pgsetup.sh [db]
cd "$(dirname "$0")/../../.."
DB=${1:-dbcraft_dev}
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres
psql -X -q -d "$DB" -c "alter system set shared_preload_libraries='pg_stat_statements'" -c "alter system set track_functions='all'" -c "alter system set jit=off" -c "alter system set autovacuum_naptime='10s'" \
     -c "alter system set shared_buffers='128MB'" -c "alter system set work_mem='64MB'" -c "alter system set max_parallel_workers_per_gather=0" -c "alter system set compute_query_id=on"
tools/pg-dev.sh stop > /dev/null
tools/pg-dev.sh start
psql -X -q -d "$DB" -c "create extension if not exists pg_stat_statements" -c "alter system set pg_stat_statements.track='all'" -c "select pg_reload_conf()" > /dev/null
