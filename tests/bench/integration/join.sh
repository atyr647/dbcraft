#!/usr/bin/env bash
# usage: tests/bench/integration/join.sh      (the e2e database must exist: tests/e2e/setup.sh; stop the gateway first)
# Measures: a player joining an EMPTY world (every chunk generated on demand), the same join into a world whose chunks exist (the packet cache serves them),
# at view distance 2 / 9 (the 441-chunk square: radius 9 + 1 = 10 -> 21 x 21) / 10 (23 x 23); and the rows and bytes a 441-chunk flat area takes.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54399} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft}
P="psql -X -q -At -v ON_ERROR_STOP=1"
$P -f tests/bench/integration/join.sql
echo "view distance | world        | chunks | join tick ms | MB sent to the joiner | frames"
for vd in 2 9 10; do
  $P -c "update mc.server_property set value = '$vd' where key in ('view-distance')" -c "select ibench.reset_world(true)" > /dev/null
  for world in "empty (generated on demand)" "chunks exist (cache hits)"; do
    if [ "$world" != "${world#empty}" ]; then CLR=true; else CLR=false; fi
    $P -c "select ibench.reset_world($CLR)" > /dev/null
    $P -F ' | ' -c "select '$vd', '$world', ((2 * ($vd + 1) + 1) ^ 2)::int, round(ms_tick::numeric, 1), mb_sent, frames from ibench.join(1, 'Bench')"
  done
done
echo
echo "storage of a 441-chunk flat area (view distance 9), after the join above generated it and the cache was filled:"
$P -c "update mc.server_property set value = '9' where key = 'view-distance'" -c "select ibench.reset_world(true)" > /dev/null
$P -c "vacuum full mc.chunk, mc.chunk_section, mc.chunk_light, mc.chunk_cache"      # the earlier runs deleted thousands of chunks: give their space back first
$P -c "select ms_tick from ibench.join(2, 'Bench')" > /dev/null
$P -c "vacuum analyze mc.chunk, mc.chunk_section, mc.chunk_light, mc.chunk_cache"
$P -F ' | ' <<'SQL'
select relname as table, n_live_tup as rows, pg_size_pretty(pg_total_relation_size(relid)) as total_with_indexes, pg_total_relation_size(relid) as bytes,
       round(pg_total_relation_size(relid)::numeric / greatest((select count(*) from mc.chunk), 1)) as bytes_per_chunk
from pg_stat_user_tables where schemaname = 'mc' and relname in ('chunk', 'chunk_section', 'chunk_light', 'chunk_cache', 'block_entity')
union all select 'TOTAL', null, pg_size_pretty(sum(pg_total_relation_size(relid))), sum(pg_total_relation_size(relid))::bigint,
       round(sum(pg_total_relation_size(relid))::numeric / greatest((select count(*) from mc.chunk), 1))
from pg_stat_user_tables where schemaname = 'mc' and relname in ('chunk', 'chunk_section', 'chunk_light', 'chunk_cache', 'block_entity')
order by 4 desc;
SQL
$P -c "select 'chunks stored: ' || count(*) || ', packet cache entries: ' || (select count(*) from mc.chunk_cache) || ', average cached packet: ' || (select round(avg(length(packet))) from mc.chunk_cache) || ' bytes' from mc.chunk"
