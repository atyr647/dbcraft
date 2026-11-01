#!/usr/bin/env bash
# Run the whole gateway-language benchmark: Tcl interpreted, Tcl compiled with tcl-aot, Rust.
#   tests/bench/tcl/run_all.sh            (needs: make tcl shell done in $TCLAOT, tcllib, cargo, python3, openssl)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TCLAOT=${TCLAOT:-/home/user/atyr647/tcl-aot}
OUT=$HERE/out; mkdir -p "$OUT"
export DATA=$HERE/data TCLLIBPATH_EXTRA=${TCLLIBPATH_EXTRA:-/usr/share/tcltk/tcllib1.21}
ROUNDS=${ROUNDS:-2}; export AES_BYTES=${AES_BYTES:-65536} AES_REPS=${AES_REPS:-2} REPS=${REPS:-5}

python3 "$HERE/gen_data.py" > /dev/null
( cd "$HERE/rust" && cargo build --release -q )
cd "$TCLAOT"; . tools/env.sh
"$TCLSH" src/translate.tcl "$HERE/gw_procs.tcl" "$OUT/gw.c" Gw 2> "$OUT/translate.log"
$CC -O2 -w -DMODULE=Gw $TBC_INC tools/module-shell.c "$OUT/gw.c" $TBC_LIBS -o "$OUT/gwshell"
cd "$HERE"
for r in $(seq 1 "$ROUNDS"); do
  "$OUT/gwshell" run.tcl                    > "$OUT/interp.$r.log" 2>&1
  COMPILED=1 "$OUT/gwshell" run.tcl         > "$OUT/aot.$r.log"    2>&1
  REPS=$((REPS*2)) "$HERE/rust/target/release/gwbench" "$DATA" > "$OUT/rust.$r.log" 2>&1
done
python3 "$HERE/summarize.py" "$OUT" "$DATA/expected.txt" ${AES_BYTES} | tee "$OUT/summary.md"
