#!/usr/bin/env bash
# Instruction counts and per-function exclusive costs for each gateway proc, interpreter alone vs tcl-aot compiled.
# Counts (valgrind callgrind) do not depend on machine load.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); T=$HERE/..; OUT=$T/out; mkdir -p "$OUT"
export TCL_LIBRARY=${TCL_LIBRARY:-/home/user/atyr647/tcl-aot/build/tcl8.6.14/library}
export TCLLIBPATH_EXTRA=${TCLLIBPATH_EXTRA:-/usr/share/tcltk/tcllib1.21}
export DATA=$T/data PROCS=${PROCS:-$T/../tcl/gw_procs.tcl} MODNAME=${MODNAME:-Gw}
SHELLBIN=${SHELLBIN:-$T/../tcl/out/gwshell}; TAG=${TAG:-base}
for p in ${PROC_LIST:-none vi_decode split_scan split_index pos_decode build_frames}; do
  for mode in interp aot; do
    if [ $mode = aot ]; then export COMPILED=1; else unset COMPILED || true; fi
    PROC=$p valgrind --tool=callgrind --callgrind-out-file="$OUT/cg.$TAG.$p.$mode" "$SHELLBIN" "$HERE/one.tcl" > "$OUT/cg.$TAG.$p.$mode.log" 2>&1 || { tail -3 "$OUT/cg.$TAG.$p.$mode.log"; exit 1; }
    callgrind_annotate "$OUT/cg.$TAG.$p.$mode" 2>/dev/null > "$OUT/cg.$TAG.$p.$mode.txt"
    echo "$TAG $p $mode $(grep -m1 -E 'PROGRAM TOTALS' -B0 "$OUT/cg.$TAG.$p.$mode.txt" | head -1)"
  done
done
