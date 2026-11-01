#!/usr/bin/env bash
# Build ../out/dbcshell (interpreter + native core) and ../out/tkshell (+ tcl-aot-compiled tick procs).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); OUT=$HERE/../out; mkdir -p "$OUT"
ORIG=${TCLAOT:-/home/user/atyr647/tcl-aot}; export BUILD=$ORIG/build
COPY=${AOTCOPY:-$ORIG}
cd "$COPY"; . tools/env.sh
cc -O2 -w -maes -msse4.1 $TBC_INC -c "$HERE/dbcnative.c" -o "$OUT/dbcnative.o"
cc -O2 -w $TBC_INC -c "$HERE/../epoll/epollnotify.c" -o "$OUT/epollnotify.o"
cc -O2 -w $TBC_INC "$HERE/dbcshell.c" "$OUT/dbcnative.o" "$OUT/epollnotify.o" $TBC_LIBS -lcrypto -o "$OUT/dbcshell"
"$TCLSH" src/translate.tcl "$HERE/tickprocs.tcl" "$OUT/tick.c" Tk 2> "$OUT/tick.translate.log"
cc -O2 -w -DMODULE=Tk $TBC_INC "$HERE/dbcshell.c" "$OUT/dbcnative.o" "$OUT/epollnotify.o" "$OUT/tick.c" $TBC_LIBS -lcrypto -o "$OUT/tkshell"
echo built dbcshell tkshell
