#!/usr/bin/env bash
# The end-to-end pass: a complete dbcraft server (PostgreSQL cluster + schema + the gateway running as database code) is built, real clients connect to it over
# TCP, and what they receive is compared with the recordings of the real vanilla 26.3 server (tests/e2e/record_vanilla.sh).
#
# usage: tests/e2e/run_all.sh        environment: DBCRAFT_E2E_DIR (default /tmp/dbcraft-e2e), DBCRAFT_PGDATA, DBCRAFT_PGPORT, DBCRAFT_CAPTURES, DBCRAFT_REPORTS
# exit code 0 when every comparison passes.  See tests/e2e/README.md.
set -uo pipefail
cd "$(dirname "$0")/../.."
E2E=${DBCRAFT_E2E_DIR:-/tmp/dbcraft-e2e}; PORT=25621
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-int} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54399}
for f in vanilla_join_returning.jsonl vanilla_block_actor.jsonl vanilla_move6.jsonl vanilla_social_first.jsonl; do
  [ -f "$E2E/$f" ] || { echo "missing $E2E/$f: run tests/e2e/record_vanilla.sh first"; exit 2; }
done
rc=0
step() { echo; echo "=== $*"; }
reset_world() { tools/pg-dev.sh psql -tAc "select mc.reset_dev_world(6)" > /dev/null; }

step "build the server database"
tests/e2e/setup.sh > "$E2E/setup.log" 2>&1 || { tail -5 "$E2E/setup.log"; exit 1; }
echo "database ready"
tests/e2e/gateway.sh start $PORT

step "join: a returning player (login, configuration, entry burst, chunks)"
reset_world
python3 tools/capture_vanilla.py --port $PORT --seconds 3 --name Probe --out "$E2E/ours_join_first.jsonl" > /dev/null
python3 tools/capture_vanilla.py --port $PORT --seconds 3 --name Probe --out "$E2E/ours_join.jsonl" > /dev/null
python3 tests/e2e/compare_join.py "$E2E/vanilla_join_returning.jsonl" "$E2E/ours_join.jsonl" || rc=1

step "block changes: break, place, break again, seen by the actor and an observer"
reset_world
python3 tests/e2e/block_probe.py --port $PORT --out "$E2E/ours_block" --actor Acta --observer Bert > /dev/null 2>&1
python3 tests/e2e/compare_block.py "$E2E/vanilla_block" "$E2E/ours_block" || rc=1

step "chunk streaming while walking across chunk borders"
reset_world
python3 tests/e2e/move_probe.py --port $PORT --name Walker --steps 6 --out "$E2E/ours_move" > /dev/null 2>&1
python3 tests/e2e/compare_move.py "$E2E/vanilla_move6.jsonl" "$E2E/ours_move.jsonl" || rc=1

step "two players: join, chat, leave"
reset_world
python3 tests/e2e/join_probe.py --port $PORT --out "$E2E/ours_social" --first Opa --second Bobb > /dev/null 2>&1
python3 tests/e2e/compare_social.py "$E2E/vanilla_social" "$E2E/ours_social" || rc=1

if [ -f "$E2E/vanilla_cmd_Op4.jsonl" ]; then
  step "commands: six players (levels 0 to 4), selectors, feedback, the command tree of every level (tests/e2e/record_commands.sh)"
  reset_world
  python3 tests/e2e/cmd_ops.py | tools/pg-dev.sh psql -q
  tools/pg-dev.sh psql -qc "update mc.server_property set value = '$(python3 tests/e2e/cmd_seed.py "$E2E/vanilla_cmd")' where key = 'level-seed'"
  python3 tests/e2e/cmd_probe.py --port $PORT --out "$E2E/ours_cmd" --wait 0.3 > /dev/null 2>&1
  python3 tests/e2e/compare_commands.py "$E2E/vanilla_cmd" "$E2E/ours_cmd" || rc=1
else
  echo; echo "(commands: skipped, no $E2E/vanilla_cmd_Op4.jsonl: run tests/e2e/record_commands.sh once)"
fi

step "gateway status"
tests/e2e/gateway.sh status
tests/e2e/gateway.sh stop
echo
[ $rc = 0 ] && echo "ALL END-TO-END COMPARISONS PASSED" || echo "SOME END-TO-END COMPARISONS FAILED"
exit $rc
