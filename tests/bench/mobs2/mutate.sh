#!/usr/bin/env bash
# mutation check: apply a mutated copy of an sql file to a scratch database cloned from $PGDATABASE (a database made by tests/bench/entity/setup_db.sh with the tree applied), run a test file there: it must FAIL.
# usage: tests/bench/mobs2/mutate.sh SQLFILE REGEX REPLACEMENT TESTFILE [EXTRA_SQLFILE_TO_APPLY_AFTER]        env: PGHOST PGPORT PGUSER PGDATABASE
cd "$(dirname "$0")/../../.."
f=$1; old=$2; new=$3; test=$4; after=${5:-}
mkdir -p .scratch
python3 tools/mutate_sql.py "$f" "$old" "$new" > .scratch/mutant.sql || { echo "mutation did not apply"; exit 2; }
tpl=$PGDATABASE
psql -X -q -d postgres -c "drop database if exists mutscratch" -c "create database mutscratch template $tpl" 2>&1 | grep -v NOTICE
psql -X -q -d mutscratch -v ON_ERROR_STOP=1 -f .scratch/mutant.sql 2>&1 | grep -v NOTICE | head -3
for a in $after; do psql -X -q -d mutscratch -v ON_ERROR_STOP=1 -f "$a" 2>&1 | grep -v NOTICE | head -3; done
if psql -X -q -d mutscratch -v ON_ERROR_STOP=1 -f tests/sql/_harness.sql -f "$test" > .scratch/mutant.out 2>&1; then echo "MUTANT SURVIVED ($f: $old)"; else grep -E "FAIL|ERROR" .scratch/mutant.out | grep -v 'schema "mc" does not exist' | head -2 | cut -c1-220; echo "mutant killed ($f: $old)"; fi
psql -X -q -d postgres -c "drop database if exists mutscratch" 2>&1 | grep -v NOTICE
