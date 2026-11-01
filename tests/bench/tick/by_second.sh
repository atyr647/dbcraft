#!/usr/bin/env bash
# usage: tests/bench/tick/by_second.sh DB [PORT]
# Wall and on-CPU time of the last tests/bench/tick/run.sh run in DB, averaged by tick modulo 20 (the position inside the second): shows what the once-a-second work costs.
set -euo pipefail
export PGHOST=/tmp PGPORT=${2:-54411} PGUSER=postgres PGDATABASE=$1
psql -X -q -At -c "select 'wall ms by tick%20: ' || string_agg(k || ':' || w, '  ' order by k) || E'\ncpu  ms by tick%20: ' || string_agg(k || ':' || c, '  ' order by k) from (select tick % 20 as k, round(avg(wall_ms)::numeric, 1) as w, round(avg(cpu_ms)::numeric, 1) as c from tickbench.step where tick > 40 group by 1) t"
