#!/usr/bin/env bash
# Build a gateway shell from a (patched) copy of tcl-aot's translator, reusing the original Tcl build.
#   patch_build.sh COPYDIR OUTDIR NAME     -> OUTDIR/NAME.c and OUTDIR/NAME-shell
set -euo pipefail
COPY=$1; OUT=$2; NAME=$3; HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
ORIG=${TCLAOT:-/home/user/atyr647/tcl-aot}; mkdir -p "$OUT"
export BUILD=$ORIG/build TCLLIBPATH_EXTRA=${TCLLIBPATH_EXTRA:-/usr/share/tcltk/tcllib1.21}
cd "$COPY"; . tools/env.sh
"$TCLSH" src/translate.tcl "${PROCS:-$HERE/../tcl/gw_procs.tcl}" "$OUT/$NAME.c" Gw 2> "$OUT/$NAME.translate.log"
$CC -O2 -w -DMODULE=Gw $TBC_INC tools/module-shell.c "$OUT/$NAME.c" $TBC_LIBS -o "$OUT/$NAME-shell"
echo built "$OUT/$NAME-shell"
