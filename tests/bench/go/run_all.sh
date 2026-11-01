#!/usr/bin/env bash
# Reproduce docs/GO-EVALUATION.md.  Needs Go 1.24+, python3, taskset; the shared inputs come from tests/bench/tcl/gen_data.py (needs openssl).
#   tests/bench/go/run_all.sh            about 10 minutes (the socket scenarios take ~40 s each)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=$PATH:/usr/local/go/bin GOTOOLCHAIN=local GOFLAGS=-mod=mod
cd "$HERE"; mkdir -p bin out
[ -f ../tcl/data/expected.txt ] || python3 ../tcl/gen_data.py >/dev/null
go build -o bin/gobench ./micro && go build -o bin/sockserver ./sock/server && go build -o bin/sockclient ./sock/client
rm -f out/go.*.log out/go4.*.log
for r in 1 2 3 4 5; do echo "micro round $r: $(uptime | sed 's/.*load/load/')"; GOMAXPROCS=1 REPS=5 bin/gobench ../tcl/data > out/go.$r.log 2>&1; done
GOMAXPROCS=4 REPS=5 bin/gobench ../tcl/data > out/go4.1.log 2>&1
python3 - <<'PY'   # every RESULT line must match the Python/openssl oracle (extra Go-only checks must say ok=1)
import re
exp={re.sub(r' clen=\d+','',l.strip()) for l in open('../tcl/data/expected.txt') if l.strip()}
bad=[]
for l in open('out/go.1.log'):
    if l.startswith('RESULT'):
        n=re.sub(r' clen=\d+','',l.strip())
        if n not in exp and 'ok=1' not in n and not n.startswith(('RESULT split_nocopy','RESULT coro')): bad.append(n)
print('oracle check:', 'all RESULT lines match' if not bad else bad)
PY
{ PACE_MS=200 ./run_sock.sh 5000; ./run_sock.sh 5000
  PACE_MS=500 ./run_sock.sh 19000; PACE_MS=200 ./run_sock.sh 19000; ./run_sock.sh 19000
  PACE_MS=200 ./run_sock.sh 19000 GOGC=10 HOLD_NOSCAN_MB=1024; PACE_MS=200 ./run_sock.sh 19000 GOGC=10 HOLD_PTR_MB=1024
  PACE_MS=500 ./run_sock.sh 19000 GOGC=10 HOLD_PTR_MB=1024; PACE_MS=500 ./run_sock.sh 19000 HOLD_PTR_MB=1024 DUR=40; } 2>&1 | tee out/sock_all.txt
python3 summarize.py | tee out/summary.md
