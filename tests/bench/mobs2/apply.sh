#!/usr/bin/env bash
# apply the entity sql files to the dev database: apply.sh [db]
cd /home/user/dbcraft/.claude/worktrees/agent-a6d9ca3c0d32000fc
export PGHOST=/tmp PGPORT=57411 PGUSER=postgres PGDATABASE=${1:-dbcraft_dev}
for f in 510_entity_physics 541_entity_lanes 550_entity_split 551_entity_fanout 940_entity_auto_lanes 941_entity_auto_perf 942_entity_aux; do
  [ -f sql/$f.sql ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -f sql/$f.sql || echo "FAIL $f"
done
