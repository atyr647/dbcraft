#!/usr/bin/env bash
# The dbcraft side of the V/D alternation of part 2: the tree before lazy lanes (OLD_DB: part 1 of this work) and the tree with them (NEW_DB), each on a freshly regenerated flat area (reset=1).
# `n` scenarios: also with NOBODY connected (new-nobody); `v` scenarios 2000/5000: also with every mob walking all the time (new-walk1: how the scoreboard campaign ran its in-view rows).
# usage: tests/bench/mobs2/after2.sh CODE REP OUTDIR        env: PGHOST PGPORT PGUSER; OLD_DB (default mob3old), NEW_DB (default dbcraft)
set -uo pipefail
cd "$(dirname "$0")/../../.."
code=$1; rep=$2; out=$3
OLD=${OLD_DB:-mob3old}; NEW=${NEW_DB:-dbcraft}
PGDATABASE=$OLD tests/bench/mobs2/run_one.sh "$code" "$rep" old "$out/dbcraft.txt" -v warm=150 -v reset=1 2>&1 | grep -v NOTICE
PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new "$out/dbcraft.txt" -v warm=150 -v reset=1 2>&1 | grep -v NOTICE
case "$code" in
  *n) PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new-nobody "$out/dbcraft.txt" -v warm=150 -v reset=1 -v viewers=0 2>&1 | grep -v NOTICE ;;
  2000v|5000v) PGDATABASE=$NEW tests/bench/mobs2/run_one.sh "$code" "$rep" new-walk1 "$out/dbcraft.txt" -v warm=150 -v reset=1 -v walk=1.0 2>&1 | grep -v NOTICE ;;
esac
