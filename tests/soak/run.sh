#!/usr/bin/env bash
# Long-run guard: N scripted clients walk for M minutes against a freshly built dbcraft database (own cluster, own ports).  FAILS (exit 1) when
#   * the per-tick time grows by more than a factor between the first and the last quarter of the steady state (SQL tick and gateway loop),
#   * any client is dropped (the bug this guard exists for: every client timed out about four minutes in, docs/SOAK.md),
#   * a queue table (net.inbox, net.outbox, mc.play_out, ...) exceeds a size bound.
#
# usage: tests/soak/run.sh [plpython|rust] [MINUTES=10] [CLIENTS=200]
#   plpython   the development gateway (`call net.run`) with tools/janitor.sh next to it (what that gateway needs, see docs/SOAK.md)
#   rust       the zero-crate gateway (gateway/build.sh), whose maintenance thread does the janitor's work
# environment: DBCRAFT_PGDATA (default /tmp/dbcraft-pg-soak), DBCRAFT_PGPORT (54744), DBCRAFT_SOAK_PORT (25671), DBCRAFT_CAPTURES / DBCRAFT_REPORTS as for tests/e2e/setup.sh,
#              SOAK_KEEP_DB=1 reuse the database of the last run (faster, skips the rebuild), SOAK_MAX_GROWTH (2.0), SOAK_MAX_QUEUE_MB (64), SOAK_TICK=default|batched
# Takes MINUTES + about 2 minutes; the sample table is written to /tmp/soak-<kind>.jsonl (tools/soak/report.py tabulates it).
set -euo pipefail
cd "$(dirname "$0")/../.."
KIND=${1:-plpython}
MINUTES=${2:-10}
CLIENTS=${3:-200}
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-soak} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54744} DBCRAFT_SOAK_PORT=${DBCRAFT_SOAK_PORT:-25671}
if [ "${SOAK_KEEP_DB:-0}" != 1 ]; then
  tests/e2e/setup.sh > /tmp/soak-setup.log 2>&1 || { echo "database setup failed, see /tmp/soak-setup.log"; exit 2; }
fi
if [ "$KIND" = rust ] && [ ! -x gateway/target/dbcraft-gateway ]; then gateway/build.sh > /tmp/soak-build.log 2>&1 || { echo "gateway build failed, see /tmp/soak-build.log"; exit 2; }; fi
EXTRA=""
if [ "$KIND" = plpython ]; then EXTRA="--janitor"; fi
exec python3 tools/soak/soak.py --kind "$KIND" --setup --check --n "$CLIENTS" --minutes "$MINUTES" --tick "${SOAK_TICK:-default}" \
     --max-growth "${SOAK_MAX_GROWTH:-2.0}" --max-queue-mb "${SOAK_MAX_QUEUE_MB:-64}" --out "/tmp/soak-$KIND.jsonl" $EXTRA
