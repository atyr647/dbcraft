#!/usr/bin/env bash
# Whole Ada benchmark batch: Rust baseline + 4 Ada builds, ROUNDS rounds each, in the same batch (other processes load the CPUs: uptime is logged).
#   tests/bench/ada/run_all.sh        needs: gnat/gnatmake, libcrypto/libz dev, cargo, python3 (tests/bench/tcl/gen_data.py makes the inputs)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TCL=$HERE/../tcl
DATA=${DATA:-$TCL/data}; OUT=$HERE/out; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-2}; export REPS=${REPS:-5}
[ -f "$DATA/expected.txt" ] || python3 "$TCL/gen_data.py" >/dev/null
( cd "$TCL/rust" && cargo build --release -q )
"$HERE/build.sh"
VARIANTS="O2 O2_nochecks O2_gnata adacraft_flags"
for r in $(seq 1 "$ROUNDS"); do
  echo "round $r load: $(cat /proc/loadavg)" | tee -a "$OUT/load.log"
  REPS=$((REPS*2)) "$TCL/rust/target/release/gwbench" "$DATA" > "$OUT/rust.$r.log" 2>&1
  for v in $VARIANTS; do
    echo "  $v load: $(cat /proc/loadavg)" >> "$OUT/load.log"
    "$HERE/bin/gwbench_$v" "$DATA" > "$OUT/ada_$v.$r.log" 2>&1
  done
done
python3 "$HERE/summarize.py" "$OUT" | tee "$OUT/summary.md"
