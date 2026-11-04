#!/usr/bin/env bash
# The dbcraft side of the V/D alternation (tools/entity/vanilla_mobs.py --after): called while the vanilla JVM is stopped.
# usage: tests/bench/mobs2/after.sh CODE REP OUTDIR        env: PGHOST PGPORT PGUSER; databases: OLD_DB (default dbcraft: the tree before this work), NEW_DB (default dbcraft_dev)
set -uo pipefail
cd "$(dirname "$0")/../../.."
code=$1; rep=$2; out=$3
OLD=${OLD_DB:-dbcraft}; NEW=${NEW_DB:-dbcraft_dev}
PGDATABASE=$OLD tests/bench/mobs2/run_one.sh "$code" "$rep" old "$out/dbcraft.txt" 2>&1 | grep -v NOTICE
PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new "$out/dbcraft.txt" 2>&1 | grep -v NOTICE
case "$code" in
  2000v|5000v)      # every mob walks all the time (walk probability 1.0): the worst case for the lanes, the old and the new engine
    PGDATABASE=$OLD tests/bench/mobs2/run_one.sh "$code" "$rep" old-walk1 "$out/dbcraft.txt" -v walk=1.0 2>&1 | grep -v NOTICE
    PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new-walk1 "$out/dbcraft.txt" -v walk=1.0 2>&1 | grep -v NOTICE ;;
esac
case "$code" in
  2000v|5000v|2000n|5000n) PGDATABASE=$NEW tests/bench/mobs2/split.sh "$code" "new r$rep" "$out/split.txt" 150 2>&1 | grep -v NOTICE ;;
esac
