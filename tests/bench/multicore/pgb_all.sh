#!/usr/bin/env bash
# usage: pgb_all.sh OUTFILE      the raw-scaling table of docs/PERF-MULTICORE.md (about seven minutes; the machine must be otherwise idle)
#   environment: PGHOST PGPORT PGUSER of a scratch cluster with the recommended settings (docker/postgresql.conf), database pgb (created here if missing)
set -uo pipefail
DIR="$(dirname "$0")"
OUT=${1:-/tmp/mc_pgb_all.txt}
: > "$OUT"
psql -X -q -d postgres -c "create database pgb" 2>/dev/null
psql -X -q -d pgb -v ON_ERROR_STOP=1 -f "$DIR/pgb_setup.sql" > /dev/null
psql -X -q -d pgb -f "$DIR/pgb_ff40.sql" > /dev/null 2>&1
psql -X -q -d pgb -f "$DIR/pgb_ffs.sql" > /dev/null 2>&1
{ echo "# $(lscpu | grep -E '^(Model name|Thread|Core|Socket)' | tr -s ' ' | tr '\n' ';')"; grep -E '^(cpu |steal)' /proc/stat | head -1; } >> "$OUT"
bash "$DIR/pgb_scale.sh" 2 5 cpu compute upd_log upd_unl queue tick tick_shared >> "$OUT" 2>&1
{ echo "# wait events, tick workload, 4 clients"; bash "$DIR/waits_run.sh" tick 4 6; echo "# wait events, upd_log workload, 4 clients"; bash "$DIR/waits_run.sh" upd_log 4 6; } >> "$OUT" 2>&1
echo "# done" >> "$OUT"
