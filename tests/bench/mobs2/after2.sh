#!/usr/bin/env bash
# The dbcraft side of the V/D alternation of part 2 (tools/entity/vanilla_mobs.py --after): the tree before lazy lanes (OLD_DB) and the tree with them (NEW_DB), on a freshly regenerated flat area.
# usage: tests/bench/mobs2/after2.sh CODE REP OUTDIR        env: PGHOST PGPORT PGUSER; OLD_DB (default mob3old), NEW_DB (default dbcraft)
set -uo pipefail
cd "$(dirname "$0")/../../.."
code=$1; rep=$2; out=$3
OLD=${OLD_DB:-mob3old}; NEW=${NEW_DB:-dbcraft}
PGDATABASE=$OLD tests/bench/mobs2/run_one.sh "$code" "$rep" old "$out/dbcraft.txt" -v warm=150 -v reset=1 2>&1 | grep -v NOTICE
PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new "$out/dbcraft.txt" -v warm=150 -v reset=1 2>&1 | grep -v NOTICE
case "$code" in
  *n) PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new-nobody "$out/dbcraft.txt" -v warm=150 -v reset=1 -v viewers=0 2>&1 | grep -v NOTICE
      PGDATABASE=$OLD tests/bench/mobs2/run_one.sh "$code" "$rep" old-nobody "$out/dbcraft.txt" -v warm=150 -v reset=1 -v viewers=0 2>&1 | grep -v NOTICE ;;
esac
case "$code" in
  2000v|5000v)      # every mob walks all the time (walk probability 1.0), as the scoreboard campaign ran its in-view rows
    PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new-walk1 "$out/dbcraft.txt" -v warm=150 -v reset=1 -v walk=1.0 2>&1 | grep -v NOTICE
    PGDATABASE=$OLD tests/bench/mobs2/run_one.sh "$code" "$rep" old-walk1 "$out/dbcraft.txt" -v warm=150 -v reset=1 -v walk=1.0 2>&1 | grep -v NOTICE ;;
esac
