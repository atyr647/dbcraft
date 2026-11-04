#!/usr/bin/env bash
# Which ticks of a bench.sql run are the expensive ones?  Runs bench.sql with the per-tick rows kept and prints the eight slowest ticks and the mean CPU by tick mod 20.
# usage: tests/bench/mobs2/spikes.sh -v mobs=2000 -v where=view -v ticks=100        env: PGHOST PGPORT PGUSER PGDATABASE
cd "$(dirname "$0")/../../.."
tmp=$(mktemp)
sed 's/^select format(/create temp table _keep as select * from _t;\nselect format(/' tests/bench/mobs2/bench.sql > "$tmp"
printf "select tick, round(cpu::numeric, 1) as cpu_ms, awake, rows_out from _keep order by cpu desc limit 8;\nselect tick %% 20 as t20, round(avg(cpu)::numeric, 1) as avg_cpu from _keep group by 1 order by 2 desc limit 4;\n" >> "$tmp"
psql -X -q -At -v label=x "$@" -f "$tmp" 2>&1 | tail -14
rm -f "$tmp"
