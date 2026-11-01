#!/usr/bin/env bash
# Elixir (+S 1 and +S 4) vs the Rust baseline, same batch, same data.   tests/bench/elixir/run_all.sh
#   ROUNDS=2 REPS=5   (best of ROUNDS x REPS for Elixir, ROUNDS x 10 for Rust)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); OUT=$HERE/out; mkdir -p "$OUT"
export DATA=$HERE/../tcl/data; ROUNDS=${ROUNDS:-2}; export REPS=${REPS:-5}
[ -f "$DATA/expected.txt" ] || python3 "$HERE/../tcl/gen_data.py" >/dev/null
( cd "$HERE/../tcl/rust" && cargo build --release -q )
: > "$OUT/load.log"
for r in $(seq 1 "$ROUNDS"); do
  echo "round $r: loadavg=$(cut -d' ' -f1-3 /proc/loadavg) cpu_pressure=$(head -1 /proc/pressure/cpu)" | tee -a "$OUT/load.log"
  REPS=$((REPS*2)) "$HERE/../tcl/rust/target/release/gwbench" "$DATA" > "$OUT/rust.$r.log" 2>&1
  elixir --erl "+S 1:1" "$HERE/bench.exs" > "$OUT/ex_s1.$r.log" 2>&1
  elixir --erl "+S 4:4" "$HERE/bench.exs" > "$OUT/ex_s4.$r.log" 2>&1
  echo "round $r done: loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" | tee -a "$OUT/load.log"
done
python3 "$HERE/summarize.py" "$OUT" "$DATA/expected.txt" | tee "$OUT/summary.md"
