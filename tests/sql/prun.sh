#!/usr/bin/env bash
# Parallel, isolated SQL test runner.
#   usage: [JOBS=4] [DBCRAFT_TESTDB=prefix] tests/sql/prun.sh [name-pattern]
# Builds ONE template database (migration + reference data + datapack + static packets + world reference), then clones it for every test file
# (CREATE DATABASE ... TEMPLATE, about a second) and runs the files JOBS at a time, each in its own database that is dropped afterwards.
# Why: (1) wall time: the sequential runner uses one core; (2) isolation: a test cannot depend on what an earlier test left behind or
# silently hide a migration problem by state it installed; a test that needs more than the template must load it itself.
# The structural checks (override list, clean migration, inlining guard) run at the end exactly as in run.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tools/env.sh
export DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54329}
JOBS=${JOBS:-4}
PREFIX=${DBCRAFT_TESTDB:-dbcraft_p}
TPL="${PREFIX}_tpl"
tools/pg-dev.sh start >/dev/null 2>&1 || true
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres
ADMIN="psql -X -q -d postgres -v ON_ERROR_STOP=1"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/prun.XXXXXX"); trap 'rm -rf "$OUT"' EXIT
t0=$(date +%s)

echo "== template database $TPL"
$ADMIN -c "drop database if exists $TPL" -c "create database $TPL" 2>/dev/null
( export PGDATABASE=$TPL
  tools/migrate.sh --fresh >/dev/null 2>&1 || { echo "FAIL migration"; exit 1; }
  REPORTS=${DBCRAFT_REPORTS:-${DBCRAFT_HOME:-$HOME/.cache/dbcraft}/reports}
  if [ -d "$REPORTS" ]; then tools/load_reports.py >/dev/null || { echo "FAIL load_reports"; exit 1; }; else echo "NOTE: no reports found; tests needing ref.* data will fail"; fi
  CAP="$(python3 tools/capture_to_tsv.py --path play_nocomp 2>/dev/null || true)"
  if [ -n "$CAP" ]; then
    python3 tools/load_datapack.py "$CAP" >/dev/null 2>&1 && python3 tools/load_static_packets.py "$CAP" >/dev/null 2>&1 && python3 tools/load_world_ref.py >/dev/null 2>&1 && python3 tools/load_recipes.py >/dev/null 2>&1 \
      || echo "NOTE: datapack/static packets/world reference could not be loaded into the template (tests load what they need themselves)"
    python3 tools/load_dynamics.py >/dev/null 2>&1 || echo "NOTE: no world-dynamics data (tools/gen_dynamics.sh): the dynamics tests skip"
    python3 tools/load_sounds.py >/dev/null 2>&1 || echo "NOTE: no block sound data (tools/gen_sounds.sh): the placement sound tests skip"
  else echo "NOTE: no capture file; tests that need the vanilla capture are skipped by their own checks"; fi
  python3 tools/load_item_components.py >/dev/null 2>&1 || echo "NOTE: no item components loaded (tests of worn-item attributes skip)"
) || exit 1
echo "   template ready in $(( $(date +%s) - t0 )) s"

run_one() {   # $1 = test file; prints PASS/FAILED line and details to a result file
  f="$1"; n=$(basename "$f" .sql); db="${PREFIX}_$$_${n//[^a-zA-Z0-9_]/_}"; db="${db:0:60}"
  res="$OUT/$n.res"
  psql -X -q -d postgres -c "create database \"$db\" template \"$TPL\"" >/dev/null 2>"$OUT/$n.err" || { echo "FAILED $f (cannot clone template: $(head -c 200 "$OUT/$n.err"))" >"$res"; return; }
  # database-level settings (ALTER DATABASE ... SET) belong to one database and are NOT copied by CREATE DATABASE ... TEMPLATE: replay what the migration does
  PGDATABASE="$db" psql -X -q -f sql/450_tuning.sql >/dev/null 2>&1
  s=$(date +%s)
  if out=$(PGDATABASE="$db" psql -X -q -v ON_ERROR_STOP=1 -f tests/sql/_harness.sql -f "$f" 2>&1); then
    k=$(printf '%s\n' "$out" | grep -c "NOTICE:  ok"); echo "PASS $f ($k checks, $(( $(date +%s) - s )) s)" >"$res"
  else
    { printf '%s\n' "$out" | grep -E "FAIL|ERROR|LINE" | sed 's/^psql:[^ ]* //' | head -8; echo "FAILED $f"; } >"$res"
  fi
  psql -X -q -d postgres -c "drop database if exists \"$db\"" >/dev/null 2>&1
}
export -f run_one; export OUT PREFIX TPL PGHOST PGPORT PGUSER

echo "== running with $JOBS jobs"
ls tests/sql/[0-9]*${1:-}*.sql | xargs -P "$JOBS" -I{} bash -c 'run_one {}'
fail=0; total=0
for f in $(ls tests/sql/[0-9]*${1:-}*.sql); do
  n=$(basename "$f" .sql); cat "$OUT/$n.res" 2>/dev/null || { echo "FAILED $f (no result)"; fail=1; }
  grep -q "^FAILED" "$OUT/$n.res" 2>/dev/null && fail=1
  k=$(grep -o "([0-9]* checks" "$OUT/$n.res" 2>/dev/null | grep -o "[0-9]*"); total=$(( total + ${k:-0} ))
done
echo "total checks: $total  (wall $(( $(date +%s) - t0 )) s, $JOBS jobs)"
echo "--- structural checks"
tools/check_overrides.py || fail=1
[ -x tools/check_inlining.sh ] && { tools/check_inlining.sh 2>&1 | grep -E "^(ok|FAIL)" || fail=1; }
tools/check_fresh_migration.sh 2>&1 | grep -E "^(ok|FAIL)" || fail=1
$ADMIN -c "drop database if exists $TPL" 2>/dev/null
exit $fail
