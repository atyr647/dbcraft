#!/usr/bin/env bash
# usage: tests/bench/inline/explain_ticks.sh FUNC_NAME [PLAYERS] [FRACTION] > plans.txt
# Runs 20 warm-up ticks, then 3 ticks with auto_explain (nested statements, verbose, every statement) and prints the plans of the statements whose plan
# still shows a CALL of FUNC_NAME (e.g. proto.varint( ): the places where the planner did not inline it.  Output: "Query Text" plus the matching Output lines.
# env: DBCRAFT_PGPORT (54329), DBCRAFT_BENCH_DB (dbcraft_inl_bench), DBCRAFT_PGLOG (server log, default /tmp/dbcraft-pg/log; must be the log of that cluster)
# auto_explain does not see plpgsql "simple expressions" (they are evaluated without an executor): those never show up here.
set -euo pipefail
cd "$(dirname "$0")/../../.."
FN=${1:?function name, e.g. proto.varint}; N=${2:-500}; FRAC=${3:-1.0}
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres PGDATABASE=${DBCRAFT_BENCH_DB:-dbcraft_inl_bench}
export PGOPTIONS="-c client_min_messages=warning"
LOG=${DBCRAFT_PGLOG:-/tmp/dbcraft-pg/log}
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql -f tests/bench/tick/cpu.sql > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate tickbench.step" -c "select ibench.setup($N, 100, 10)" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "select count(*) from mc.refresh_visibility()" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "vacuum (full, analyze) mc.player, net.conn, mc.visible" > /dev/null
SCRIPT=$(mktemp); trap 'rm -f "$SCRIPT"' EXIT
printf 'select setseed(0.99) is null;\n' > "$SCRIPT"
for i in $(seq 1 23); do
  if [ "$i" = 21 ]; then printf "load 'auto_explain';\nset auto_explain.log_min_duration = 0;\nset auto_explain.log_nested_statements = on;\nset auto_explain.log_verbose = on;\nset auto_explain.log_analyze = off;\n"; fi
  printf 'select ibench.gen(%s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$FRAC"
done >> "$SCRIPT"
START=$(stat -c %s "$LOG")
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$SCRIPT"
tail -c +"$((START + 1))" "$LOG" | python3 -I -c "
import re, sys
fn = sys.argv[1]
text = sys.stdin.read()
# one auto_explain entry per 'LOG:  duration: ... plan:' block
blocks = re.split(r'(?m)^\d{4}-\d\d-\d\d [\d:.]+ \w+ \[\d+\] ', text)
seen = {}
for b in blocks:
    if 'Query Text:' not in b: continue
    q = re.search(r'Query Text: (.*?)\n\s*(?:Result|Insert|Update|Delete|Seq|Index|Nested|Hash|Sort|Aggregate|Subquery|Function|Values|CTE|Limit|Merge|Bitmap|Group|Unique|Append|ProjectSet|WindowAgg|Materialize|Gather|Sample|Tid)', b, re.S)
    qt = (q.group(1) if q else '?').strip()
    lines = [l.strip() for l in b.split('\n') if fn + '(' in l and re.match(r'\s*(?:->\s*)?(Output|Filter|Join Filter|Hash Cond|Index Cond|Recheck Cond|Sort Key|Group Key|Function Call|One-Time Filter|Merge Cond|Rows Removed by)', l.strip().lstrip('-> ').strip() and l.strip())]
    if lines:
        k = re.sub(r'\s+', ' ', qt)[:240]
        d = seen.setdefault(k, [0, set()])
        d[0] += 1
        for l in lines:
            for m in re.finditer(re.escape(fn) + r'\(', l):
                d[1].add('...' + l[max(0, m.start() - 70): m.end() + 90] + '...')
for k, (n, ls) in sorted(seen.items(), key=lambda kv: -kv[1][0]):
    print(f'== {n}x  {k}')
    for l in sorted(ls)[:4]: print('     ', l)
" "$FN"
