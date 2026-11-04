#!/usr/bin/env bash
# Shrink the world tables of an existing database to the compact storage profile (sql/950, docs/PERF-DISK.md).
#
# usage: tools/compact_world.sh [--apply-sql] [--compression pglz|lz4] [--no-vacuum]
#   --apply-sql         first apply the files that introduce the profile (sql/245, sql/291, sql/950) to this database.  tools/migrate.sh runs the whole sql/ directory and
#                       is meant for a fresh database (a second run stops at the view of sql/210), so an EXISTING database takes these three files and nothing else
#   --compression M     compress the rewritten rows with M (default pglz, the smallest; rows written afterwards use the profile's own method, lz4)
#   --no-vacuum         stop after the rewrite (the dead row versions stay until a VACUUM FULL you run yourself)
# The connection comes from the usual libpq variables (PGHOST, PGPORT, PGUSER, PGDATABASE) or DBCRAFT_PSQL.
#
# What it does: (1) mc.compact_world_storage(): every row of mc.chunk, mc.chunk_section, mc.chunk_light and mc.chunk_cache is formed again and compressed; the content is
# byte for byte the same.  (2) VACUUM FULL of the four tables: the old row versions and the free space of the half-empty pages go, the indexes are rebuilt (about 30% smaller).
# Needs the disk for a second copy of the largest table, takes an ACCESS EXCLUSIVE lock (the server's tick waits: stop the gateway first) and writes WAL for the whole world.
# World of 10,000 flat chunks: 1.3 s + 0.3 s; 780 imported terrain chunks: 1.1 s + 0.1 s.
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL=${DBCRAFT_PSQL:-psql}
APPLY=0; COMP=pglz; VAC=1
while [ $# -gt 0 ]; do
  case "$1" in
    --apply-sql) APPLY=1 ;;
    --compression) COMP=${2:?}; shift ;;
    --no-vacuum) VAC=0 ;;
    *) sed -n 2,13p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done
case "$COMP" in pglz|lz4) ;; *) echo "compression must be pglz or lz4" >&2; exit 2 ;; esac
size() { $PSQL -X -q -At -c "select round(sum(pg_total_relation_size(c.oid)) / 1048576.0, 2) || ' MiB in ' || (select count(*) from mc.chunk) || ' chunks, ' || coalesce(round(sum(pg_total_relation_size(c.oid))::numeric / nullif((select count(*) from mc.chunk), 0)), 0) || ' bytes per chunk' from pg_class c where c.relnamespace = 'mc'::regnamespace and c.relname in ('chunk', 'chunk_section', 'chunk_light', 'chunk_cache', 'block_entity')"; }
if [ "$APPLY" = 1 ]; then
  for f in sql/245_world_gen.sql sql/291_section_compression.sql sql/950_world_storage.sql; do
    echo "== $f"
    $PSQL -X -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v "already exists, skipping" || true
  done
fi
old=$($PSQL -X -q -At -c "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and backend_xmin is not null and xact_start < now() - interval '5 seconds'")
if [ "${old:-0}" != 0 ]; then
  echo "WARNING: $old session(s) (in any database) hold a transaction open: VACUUM FULL cannot remove the old row versions they might still see, and the tables would end up BIGGER, not smaller. Stop the gateway and the other sessions first." >&2
fi
echo "before: $(size)"
$PSQL -X -q -At -v ON_ERROR_STOP=1 -c "select 'rewrote ' || mc.compact_world_storage('$COMP') || ' rows'"
if [ "$VAC" = 1 ]; then
  $PSQL -X -q -v ON_ERROR_STOP=1 -c "vacuum full mc.chunk, mc.chunk_section, mc.chunk_light, mc.chunk_cache, mc.block_entity" -c "analyze mc.chunk, mc.chunk_section, mc.chunk_light, mc.chunk_cache"
  $PSQL -X -q -c checkpoint
fi
echo "after:  $(size)"
