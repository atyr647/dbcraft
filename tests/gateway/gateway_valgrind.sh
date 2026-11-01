#!/usr/bin/env bash
# Runs the DEBUG gateway build under valgrind, so that any test that starts "the gateway binary" (tests/gateway/run_online.sh, run_e2e_rust.sh) also checks it for memory errors:
#   DBCRAFT_RUST_GATEWAY=$PWD/tests/gateway/gateway_valgrind.sh tests/gateway/run_online_rust.sh 256
# Errors and the leak summary go to ${VALGRIND_LOG:-/tmp/dbcraft-gw-valgrind.log}; exit code 9 if valgrind found an error.  Valgrind makes the gateway about 20-50x slower:
# ticks overrun while it runs (the test scripts do not mind).  Build the debug binary first: gateway/build.sh debug
cd "$(dirname "$0")/../.."
exec valgrind --error-exitcode=9 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --track-origins=yes \
  --log-file="${VALGRIND_LOG:-/tmp/dbcraft-gw-valgrind.log}" gateway/target/dbcraft-gateway-debug "$@"
