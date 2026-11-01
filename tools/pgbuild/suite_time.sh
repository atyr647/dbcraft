#!/usr/bin/env bash
# Run the whole SQL test suite (tests/sql/run.sh) against one variant's binaries on its own cluster and report wall time and the check count.
#   usage: tools/pgbuild/suite_time.sh A|D        A = distro binary, D = PGO build      output: one summary line + the non-PASS lines
# jit is forced off for BOTH (the distro binary is built with LLVM JIT and would default to jit=on; the custom builds have no JIT): PGOPTIONS reaches
# every client connection, including the psql processes that the test helpers start.
set -euo pipefail
cd "$(dirname "$0")/../.."
V=${1:?A or D}
case "$V" in
  A) unset DBCRAFT_PGBIN; export DBCRAFT_PGPORT=54506 DBCRAFT_PGDATA=/tmp/pg-data-suite-A ;;
  D) export DBCRAFT_PGBIN=/tmp/pg-runtime-D2/bin DBCRAFT_PGPORT=54507 DBCRAFT_PGDATA=/tmp/pg-data-suite-D ;;
  *) echo "variant A or D"; exit 2 ;;
esac
export DBCRAFT_TESTDB=dbcraft_rt_$(echo "$V" | tr 'A-Z' 'a-z') PGOPTIONS="-c jit=off"    # lowercase: an unquoted CREATE DATABASE folds the name
rm -rf "$DBCRAFT_PGDATA"
T0=$(date +%s)
LOG=/tmp/pgbuild/suite-$V.log
tests/sql/run.sh > "$LOG" 2>&1 || RC=$?
T1=$(date +%s)
OUT=$(cat "$LOG")
echo "$OUT" | grep -v "^PASS" | grep -E "FAIL|ERROR|LINE|overrides|ok  |structural|could not|FATAL" | head -20 || true
N=$( (echo "$OUT" | grep "^PASS" | sed -E 's/.*\(([0-9]+) checks\)/\1/' | paste -sd+ | bc) || true)
N=${N:-0}
echo "(full log: $LOG)"
echo "suite variant $V: wall $((T1 - T0)) s, $N checks passed, exit ${RC:-0}, load at the end $(cut -d' ' -f1 /proc/loadavg)"
tools/pg-dev.sh stop > /dev/null 2>&1 || true
