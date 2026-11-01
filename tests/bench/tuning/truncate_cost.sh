#!/usr/bin/env bash
# What does one "TRUNCATE a small table, COMMIT" cost, as a function of fsync, shared_buffers and the kind of table?  The dbcraft tick truncates about eight UNLOGGED
# queue tables per tick (net.batch, mc.play_in_work, net.play_inbox, mc.pending_ack, mc.block_actor ...) and ten ON COMMIT DELETE ROWS temp tables are truncated
# at every commit.  Fresh throwaway clusters, no dbcraft schema.
# usage: tests/bench/tuning/truncate_cost.sh [ROUNDS=300]     env: TC_DATA (default /tmp/dbcraft-pg-tune-tc), TC_PORT (default 54475)
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROUNDS=${1:-300}; DATA=${TC_DATA:-/tmp/dbcraft-pg-tune-tc}; PORT=${TC_PORT:-54475}
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
run_variant() {   # $1 label, rest: server options
  local label=$1; shift
  as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true
  rm -rf "$DATA"; mkdir -p "$DATA"; [ "$(id -u)" = 0 ] && chown postgres "$DATA"
  as_pg "$PGBIN/initdb -D $DATA -A trust -E UTF8 >/dev/null"
  as_pg "$PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp -c synchronous_commit=off -c jit=off $*' -l $DATA/log -w start" >/dev/null
  PGHOST=/tmp PGPORT=$PORT PGUSER=postgres psql -X -q -At -v ON_ERROR_STOP=1 <<SQL
create unlogged table u1 (i int); create unlogged table u2 (i int); create unlogged table u3 (i int); create unlogged table u4 (i int);
create table l1 (i int);
create or replace procedure bench(p_kind text, p_n int, p_k int) language plpgsql as \$\$
declare t0 timestamptz; r int; k int; t int; best float8 := 1e9; tot float8 := 0; ms float8; mx float8 := 0;
begin
  for r in 1 .. p_n loop
    t0 := clock_timestamp();
    for k in 1 .. p_k loop
      if p_kind = 'unlogged' then insert into u1 values (1); truncate u1;
      elsif p_kind = 'logged' then insert into l1 values (1); truncate l1;
      elsif p_kind = 'delete' then insert into l1 values (1); delete from l1;
      elsif p_kind = 'temp' then
        -- ten ON COMMIT DELETE ROWS temp tables with a primary key, each written once per transaction (what the tick's helper tables do); p_k is ignored
        if k = 1 then
          for t in 1 .. 10 loop
            execute format('create temp table if not exists tt%s (i int primary key) on commit delete rows', t);
            execute format('insert into tt%s values (1)', t);
          end loop;
        end if;
      end if;
    end loop;
    commit;
    ms := extract(epoch from clock_timestamp() - t0) * 1000; tot := tot + ms; best := least(best, ms); mx := greatest(mx, ms);
  end loop;
  raise notice '% x% per commit: avg % ms, best % ms, max % ms', p_kind, p_k, round((tot / p_n)::numeric, 3), round(best::numeric, 3), round(mx::numeric, 2);
end \$\$;
SQL
  for kind in unlogged logged delete temp; do
    printf '%-34s ' "$label"
    PGHOST=/tmp PGPORT=$PORT PGUSER=postgres psql -X -q -At -c "call bench('$kind', $ROUNDS, 8)" 2>&1 | sed 's/^NOTICE:  //'
  done
  PGHOST=/tmp PGPORT=$PORT PGUSER=postgres psql -X -q -At -c "select '   pg_stat_io fsyncs by client backends: ' || coalesce(sum(fsyncs), 0) from pg_stat_io where backend_type = 'client backend'" | sed "s/^/$label /"
}
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m fast stop" >/dev/null 2>&1 || true; rm -rf "$DATA"' EXIT
echo "8 truncates (or 8 delete-all) + 1 commit per measured unit, $ROUNDS units per variant; the tick does about this per tick"
run_variant "fsync=on  shared_buffers=128MB" "-c fsync=on -c shared_buffers=128MB"
run_variant "fsync=off shared_buffers=128MB" "-c fsync=off -c shared_buffers=128MB"
run_variant "fsync=on  shared_buffers=2GB" "-c fsync=on -c shared_buffers=2GB"
run_variant "fsync=on  shared_buffers=32MB" "-c fsync=on -c shared_buffers=32MB"
