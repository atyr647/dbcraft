#!/usr/bin/env bash
# Build the Odin benchmark (checked and unchecked) and run it against the Rust baseline in alternating rounds.
#   ODIN_ROOT=/path/to/Odin tests/bench/odin/run.sh        (needs tests/bench/tcl/gen_data.py run once, and the Rust baseline built)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export ODIN_ROOT=${ODIN_ROOT:-/tmp/odin-dl/odin-src}; ODIN=$ODIN_ROOT/odin
DATA=$HERE/../tcl/data; RUST=$HERE/../tcl/rust/target/release/gwbench
ROUNDS=${ROUNDS:-3}; export REPS=${REPS:-5}
mkdir -p "$HERE/bin" "$HERE/out"
( cd "$HERE" && $ODIN build . -file -o:speed -out:bin/gwbench_checked && \
  $ODIN build . -file -o:speed -disable-assert -no-bounds-check -out:bin/gwbench_unchecked )
[ -x "$RUST" ] || ( cd "$HERE/../tcl/rust" && cargo build --release -q )
for r in $(seq 1 "$ROUNDS"); do
  echo "round $r: $(uptime | sed 's/.*load average/load average/')" | tee -a "$HERE/out/load.log"
  "$RUST"                      "$DATA" > "$HERE/out/rust.$r.log"
  "$HERE/bin/gwbench_checked"   "$DATA" > "$HERE/out/odin_checked.$r.log"
  "$HERE/bin/gwbench_unchecked" "$DATA" > "$HERE/out/odin_unchecked.$r.log"
done
python3 "$HERE/summarize.py" "$HERE/out" "$DATA/expected.txt" | tee "$HERE/out/summary.md"
