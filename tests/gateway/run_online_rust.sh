#!/usr/bin/env bash
# The online-mode end-to-end test (stub Mojang session server, encrypting test client, negative cases) against the RUST gateway.
# usage: tests/gateway/run_online_rust.sh [compression_threshold [N CONCURRENCY]]       (default -1; try 256; with N: the load test)
# A thin wrapper around tests/gateway/run_online.sh: its own cluster (port 54655, data /tmp/dbcraft-pg-gw3), the gateway binary built by gateway/build.sh, and no per-address
# limits (every client of the test connects from 127.0.0.1).
set -euo pipefail
cd "$(dirname "$0")/../.."
export DBCRAFT_RUST_GATEWAY=${DBCRAFT_RUST_GATEWAY:-$PWD/gateway/target/dbcraft-gateway}
export DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54655} DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-gw3}
export DBCRAFT_GW_MAX_CONNECTIONS_PER_IP=0 DBCRAFT_GW_NEW_CONNECTIONS_PER_IP_PER_SEC=0 DBCRAFT_GW_LOGIN_ATTEMPTS_PER_IP_PER_MIN=0
exec tests/gateway/run_online.sh "$@"
