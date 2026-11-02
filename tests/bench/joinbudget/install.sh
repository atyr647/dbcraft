#!/usr/bin/env bash
# Apply the join-budget SQL (and the three edited tick input functions) to a database that was migrated before: usage: JB_DB=name tests/bench/joinbudget/install.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
for f in sql/790_join_budget.sql sql/195_net_process.sql sql/381_batch_ingest_vis.sql sql/430_tick_perf.sql; do
  tests/bench/joinbudget/psql.sh -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v NOTICE || true
done
echo installed
