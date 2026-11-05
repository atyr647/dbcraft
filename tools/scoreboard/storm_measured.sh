#!/usr/bin/env bash
# The measurement behind docs/PERF-STORM-MEASURED.md: the login storm (storm2 cells: 50 / 200 joins into 20 online players, view distance 10, Rust gateway)
# BEFORE storm round 2 (merge 7251b8c^1 = f62f0f9) and AFTER (the tree this script is run from), resumable (a cell already in the results file is skipped).
# Everything lives in /dev/shm (wiped by a container restart: `setup` rebuilds it), results are appended to docs/perf-storm-measured-results.txt and committed after every cell.
#   usage: tools/scoreboard/storm_measured.sh setup | cell after|before N REP | vanilla N | all
set -uo pipefail
cd "$(dirname "$0")/../.."
HEAD_TREE=$(pwd)
BEFORE_REV=${BEFORE_REV:-f62f0f9}
A_DIR=/dev/shm/stormm   A_PORT=56600
B_DIR=/dev/shm/stormm_b B_PORT=56610
V_DIR=/dev/shm/stormm_v V_PORT=56620
BT=/dev/shm/stormm_btree
RES=$HEAD_TREE/docs/perf-storm-measured-results.txt
LOADMAX=${LOADMAX:-3.5}

setup_tree() {      # NAME TREE_DIR CAP_DIR CAP_PORT
  local name=$1 tree=$2 cdir=$3 port=$4
  [ -x "$tree/gateway/target/dbcraft-gateway" ] || (cd "$tree" && gateway/build.sh > /dev/shm/stormm_build_$name.log 2>&1) || { echo "gateway build of $name failed"; return 1; }
  if [ ! -d "$cdir/pg/base" ] || ! psql -X -q -At -h /tmp -p "$port" -U postgres dbcraft -c "select count(*) from mc.server_property" > /dev/null 2>&1; then
    mkdir -p "$cdir"
    (cd "$tree" && CAP_DIR=$cdir CAP_PORT=$port tools/scoreboard/cenv_capacity tests/e2e/setup.sh > "$cdir/setup.log" 2>&1) || { echo "db setup of $name failed"; tail -5 "$cdir/setup.log"; return 1; }
  fi
  echo "$name ready ($tree, port $port)"
}

setup() {
  if [ ! -d $BT/sql ]; then
    mkdir -p $BT && git archive "$BEFORE_REV" | tar -x -C $BT
    # the harness of this tree (a superset: tick CPU, the pre-encoded chunk cache, resumable results) runs both trees; the server code stays the old tree's
    for f in run.py common.py dbcraft.sh cenv_capacity loadgen.py; do cp "$HEAD_TREE/tools/scoreboard/$f" "$BT/tools/scoreboard/$f"; done
  fi
  setup_tree after "$HEAD_TREE" $A_DIR $A_PORT &
  local p1=$!
  setup_tree before $BT $B_DIR $B_PORT &
  local p2=$!
  wait $p1; local r1=$?; wait $p2; local r2=$?
  return $((r1 + r2))
}

commit_results() {
  git add docs/perf-storm-measured-results.txt tools/scoreboard/storm_measured.sh tools/scoreboard/run.py 2>/dev/null
  git commit -q -m "storm measured: $1

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CKDduJaYNVZ3se3jM8Jr2F" 2>/dev/null || true
}

cell() {            # after|before N REP [extra run.py args]
  local which=$1 n=$2 rep=$3; shift 3
  local tree cdir port
  if [ "$which" = after ]; then tree=$HEAD_TREE; cdir=$A_DIR; port=$A_PORT; else tree=$BT; cdir=$B_DIR; port=$B_PORT; fi
  (cd "$tree" && CAP_DIR=$cdir CAP_PORT=$port SCORE_RESULTS=$RES tools/scoreboard/cenv_capacity python3 tools/scoreboard/run.py storm2 --n "$n" --reps 1 --servers dbcraft \
      --tag "sm-$which-r$rep" --load-max $LOADMAX --load-wait 240 --quiet-wait 0 "$@")
  commit_results "$which $n joins rep $rep"
}

vanilla() {         # N
  local n=$1 tag="sm-vanilla-r0"
  grep -q "\"tag\": \"$tag\"" "$RES" 2>/dev/null && grep "\"tag\": \"$tag\"" "$RES" | grep -q "\"n\": $n," && { echo "vanilla $n done"; return; }
  (CAP_DIR=$V_DIR CAP_PORT=$V_PORT SCORE_RESULTS=$RES SCORE_HEAP=2G SCORE_XMS=1G SCORE_XMX=2G tools/scoreboard/cenv_capacity python3 tools/scoreboard/run.py storm2 --n "$n" --reps 1 \
      --servers vanilla --tag "$tag" --load-max 3 --load-wait 600 --quiet-wait 0)
  commit_results "vanilla $n joins"
}

case "${1:-}" in
  setup) setup ;;
  cell) shift; cell "$@" ;;
  vanilla) shift; vanilla "$@" ;;
  *) echo "usage: $0 setup | cell after|before N REP | vanilla N"; exit 2 ;;
esac
