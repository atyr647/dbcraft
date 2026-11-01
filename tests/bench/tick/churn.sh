#!/usr/bin/env bash
# usage: tests/bench/tick/churn.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS] [LABEL]
# env:   DBCRAFT_PGPORT (default 54411), DBCRAFT_BENCH_DB (default dbcraft), WORKLOAD=tune (the tuning trial's synthetic gateway: also answers keep-alives and teleports)
# Counts the relation-file churn of the tick: how many relation files the backend creates (open with O_CREAT), unlinks and truncates per tick, with strace on the
# backend that runs the ticks, plus the Storage CREATE/TRUNCATE records of the WAL and the relation extends of pg_stat_io per tick.  The database must be on a cluster
# whose server runs as the current user or root (strace -p).  Needs: strace, pg_waldump.  The first 20 ticks are warm-up and are not counted (a marker query runs
# between them and the counted ticks, and the strace output is cut at the marker's openat of a file that only the marker touches).
set -euo pipefail
cd "$(dirname "$0")/../../.."
N=${1:-500}; SIDE=${2:-100}; FRAC=${3:-1.0}; TICKS=${4:-60}; LABEL=${5:-churn}
PORT=${DBCRAFT_PGPORT:-54411}; DB=${DBCRAFT_BENCH_DB:-dbcraft}
export PGHOST=/tmp PGPORT=$PORT PGUSER=postgres PGDATABASE=$DB PGOPTIONS="-c client_min_messages=warning"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GEN=ibench.gen
EXTRA=
if [ "${WORKLOAD:-bench}" = tune ]; then GEN=tune.gen; EXTRA='-f tests/bench/tuning/steady.sql'; fi
TAIL=; if [ "${WORKLOAD:-bench}" = blocks ]; then GEN=tickbench.gen_blocks; EXTRA='-f tests/bench/tuning/steady.sql'; TAIL='-f tests/bench/tick/blocks.sql'; fi   # blocks: tune + three block edits and some acknowledgements per tick   # tune: the tuning worker's trial (keep-alive and teleport answers as well)
psql -X -q -At -v ON_ERROR_STOP=1 -f tests/bench/integration/bench.sql $EXTRA -f tests/bench/tick/cpu.sql $TAIL > /dev/null 2>&1
psql -X -q -At -v ON_ERROR_STOP=1 -c "truncate tickbench.step" -c "select ibench.setup($N, $SIDE, ${VIEW:-10})" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "select count(*) from mc.refresh_visibility()" > /dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -c "vacuum (full, analyze) mc.player, net.conn, mc.visible" > /dev/null
DBOID=$(psql -X -q -At -c "select oid from pg_database where datname = '$DB'")
{
  printf 'select setseed(0.99) is null;\n'
  printf 'select pg_backend_pid() \\g %s/pid\n' "$TMP"
  printf 'select pg_sleep(2);\n'
  for i in $(seq 1 20); do printf 'select %s(%s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$GEN" "$FRAC"; done
  printf 'select pg_sleep(1);\n'
  printf 'select pg_current_wal_lsn() \\g %s/lsn0\n' "$TMP"
  printf "select sum(extends) filter (where object = 'relation'), sum(extends) filter (where object = 'temp relation'), sum(writes) from pg_stat_io \\\\g %s/io0\n" "$TMP"
  printf 'select pg_sleep(1);\n'
  for i in $(seq 1 "$TICKS"); do printf 'select %s(%s);\nselect tickbench.timed_tick();\nselect ibench.drain();\n' "$GEN" "$FRAC"; done
  printf 'select pg_sleep(1);\n'
  printf 'select pg_current_wal_lsn() \\g %s/lsn1\n' "$TMP"
  printf "select sum(extends) filter (where object = 'relation'), sum(extends) filter (where object = 'temp relation'), sum(writes) from pg_stat_io \\\\g %s/io1\n" "$TMP"
} > "$TMP/script.sql"
psql -X -q -At -v ON_ERROR_STOP=1 -o /dev/null -f "$TMP/script.sql" &
PSQL_PID=$!
while [ ! -s "$TMP/pid" ]; do sleep 0.1; done
BE=$(tr -d ' \n' < "$TMP/pid")
strace -f -y -tt -p "$BE" -e trace=openat,unlink,unlinkat,ftruncate,rename -e signal=none -o "$TMP/strace.out" 2> "$TMP/strace.err" &
STRACE_PID=$!
wait "$PSQL_PID" || true
sleep 0.5; kill "$STRACE_PID" 2> /dev/null || true; wait "$STRACE_PID" 2> /dev/null || true
if [ -n "${KEEP_STRACE:-}" ]; then cp "$TMP/strace.out" "$KEEP_STRACE"; fi   # KEEP_STRACE=file keeps the raw strace log (paths of the files touched)
LSN0=$(tr -d ' \n' < "$TMP/lsn0"); LSN1=$(tr -d ' \n' < "$TMP/lsn1")
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
DATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-tick}
WAL=$("$PGBIN/pg_waldump" -p "$DATA/pg_wal" -r Storage -s "$LSN0" -e "$LSN1" 2> /dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "CREATE" || $i == "TRUNCATE") { c[$i]++ } } END { printf "create %d truncate %d", c["CREATE"], c["TRUNCATE"] }' || true)
python3 - "$TMP/strace.out" "$TMP/io0" "$TMP/io1" "$TICKS" "$LABEL" "$DBOID" "$WAL" <<'E'
import re, sys
f, io0, io1, ticks, label, dboid, wal = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7]
lines = open(f, errors='replace').read().splitlines()
# the two one-second sleeps around the counted ticks show up as a gap between consecutive syscalls; find the two longest gaps after the first third
def secs(l):
    m = re.search(r'(\d\d):(\d\d):(\d\d\.\d+)', l)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else None
ts = [(i, secs(l)) for i, l in enumerate(lines) if secs(l) is not None]
gaps = sorted(((b[1] - a[1], b[0]) for a, b in zip(ts, ts[1:])), reverse=True)[:4]
# the sleeps: pg_sleep(2), pg_sleep(1) x3 -> four gaps >= 0.9 s; the counted window is between the second and the fourth (by position)
pos = sorted(p for g, p in gaps if g > 0.9)
if len(pos) >= 3:
    lo, hi = pos[1], pos[-1]
else:
    lo, hi = 0, len(lines)
win = lines[lo:hi]
rel = re.compile(r'"(?:base/\d+|global|pg_tblspc/[^"]*)/(t?\d+_)?(\d+)(_fsm|_vm|_init)?(\.\d+)?"')
creat = [l for l in win if 'openat' in l and 'O_CREAT' in l and 'base/' in l and not ' = -1' in l]
creat_ok = [l for l in creat if 'EEXIST' not in l]
unl = [l for l in win if re.search(r'\bunlink(at)?\(', l) and 'base/' in l and ' = 0' in l]
trunc = [l for l in win if 'ftruncate' in l and ' = 0' in l]
def forks(ls):
    c = {'main': 0, 'init': 0, 'fsm': 0, 'vm': 0}
    for l in ls:
        m = rel.search(l)
        if not m: continue
        c['init' if m.group(3) == '_init' else 'fsm' if m.group(3) == '_fsm' else 'vm' if m.group(3) == '_vm' else 'main'] += 1
    return c
def temp(ls): return sum(1 for l in ls if re.search(r'"base/\d+/t\d+_\d+', l))
print(f"{label}: ticks counted {ticks}; per tick: files created {len(creat_ok)/ticks:.1f} (temp {temp(creat_ok)/ticks:.1f}), files unlinked {len(unl)/ticks:.1f}, ftruncate {len(trunc)/ticks:.1f} (temp tables {sum(1 for l in trunc if re.search(r'/t\d+_\d+>', l))/ticks:.1f}); created by fork {forks(creat_ok)}")
a = [x.strip().split('|') for x in open(io0).read().split('\n') if x.strip()]
b = [x.strip().split('|') for x in open(io1).read().split('\n') if x.strip()]
if a and b:
    d = [(int(y or 0) - int(x or 0)) / ticks for x, y in zip(a[0], b[0])]
    print(f"{label}: pg_stat_io per tick: relation extends {d[0]:.1f}, temp relation extends {d[1]:.1f}, writes {d[2]:.1f}; WAL Storage records over the window: {wal} (per tick: see ticks)")
E
