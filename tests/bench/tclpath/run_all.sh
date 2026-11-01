#!/usr/bin/env bash
# Reproduce docs/TCL-PATH.md.  Needs: tcl-aot built (make tcl shell) in $TCLAOT, valgrind, tcllib, libssl-dev, gcc, python3.
# Takes about 10 minutes (the 4 minute tcl-aot suite run is separate: see the end).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
export TCLAOT=${TCLAOT:-/home/user/atyr647/tcl-aot} TCL_LIBRARY=${TCLAOT:-/home/user/atyr647/tcl-aot}/build/tcl8.6.14/library TCLLIBPATH_EXTRA=/usr/share/tcltk/tcllib1.21
[ -x ../tcl/out/gwshell ] || ../tcl/run_all.sh                   # builds the stock gateway shell and data (see docs/TCL-EVALUATION.md)
mkdir -p out data
echo "== 1. Amdahl: instruction counts, interpreter vs tcl-aot (eager attach)"
(cd data && ../../tcl/out/gwshell ../amdahl/gen_small_inputs.tcl && cp ../../tcl/data/pos.bin .)
TBC_EAGER=1 TAG=eager amdahl/run_callgrind.sh && python3 amdahl/classify.py out eager
echo "== 1b. gap experiment: tcl::binary::format as a pure builtin (patched COPY of tcl-aot)"
AOTCOPY=$HERE/out/aotcopy; rm -rf "$AOTCOPY"; mkdir -p "$AOTCOPY"
(cd "$TCLAOT" && tar --exclude=./build --exclude=./.git -cf - .) | tar -xf - -C "$AOTCOPY"
(cd "$AOTCOPY" && patch -p1 < "$HERE/patches/binary-format-pure.patch")
./patch_build.sh "$AOTCOPY" out purefmt
echo "== 1c. differential test of the patch"
PROCS=$HERE/difftest/bfprocs.tcl ./patch_build.sh "$AOTCOPY" out bf
for m in interp aot; do if [ $m = aot ]; then export COMPILED=1; else unset COMPILED || true; fi; TBC_EAGER=1 out/bf-shell difftest/bfrun.tcl > out/bf.$m.txt; done
diff <(grep -v COMPILEDCOUNT out/bf.interp.txt) <(grep -v COMPILEDCOUNT out/bf.aot.txt) && echo "interpreter and compiled agree"
unset COMPILED || true
echo "== 1d. split at gateway-realistic buffer sizes"
PROCS=$HERE/../tcl/gw_procs.tcl TBC_EAGER=1 ../tcl/out/gwshell amdahl/small_split.tcl
PROCS=$HERE/../tcl/gw_procs.tcl TBC_EAGER=1 COMPILED=1 ../tcl/out/gwshell amdahl/small_split.tcl
echo "== 2. native core: build, correctness, rates, per-tick pattern"
native/build.sh
out/dbcshell native/crypto_rates.tcl
out/dbcshell native/small_split_native.tcl
TBC_EAGER=1 out/dbcshell native/run_tick.tcl
TBC_EAGER=1 COMPILED=1 out/tkshell native/run_tick.tcl
echo "== 3. sockets: Tcl's select notifier vs the epoll notifier (needs ~20000 fds; loopback)"
cc -O2 -w -o out/loadgen epoll/loadgen.c -lcrypto
for spec in "select 700" "epoll 700" "select 2000" "epoll 2000" "epoll 5000"; do epoll/run_sockets.sh $spec 10 || true; done
# the tcl-aot suite on the patched copy (about 4 minutes):  (cd out/aotcopy && BUILD=$TCLAOT/build tests/run.sh quick)
