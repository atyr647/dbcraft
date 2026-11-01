#!/usr/bin/env bash
# Builds the gateway with plain rustc: no cargo, no crates.io, no build scripts.  The system libraries it links (libpq, libcrypto, libcurl, libz) are the ones
# already installed; libcurl is linked by soname (libcurl.so.4) from the #[link] attribute in src/ffi/curl.rs, so no libcurl-dev package is needed.
#
#   gateway/build.sh            release build  -> gateway/target/dbcraft-gateway
#   gateway/build.sh test       unit tests     -> runs gateway/target/gateway-tests (core tests too)
#   gateway/build.sh debug      debug build with overflow checks and debug assertions (used with valgrind)
set -euo pipefail
cd "$(dirname "$0")"
T=target
mkdir -p "$T"
FLAGS_COMMON="--edition 2021"
CORE="$T/libdbcraft_gateway_core.rlib"
mode="${1:-release}"
case "$mode" in
  release) OPT="-C opt-level=3 -C codegen-units=1 -C lto=thin -C target-cpu=x86-64-v2" ;;
  debug)   OPT="-C opt-level=1 -C debuginfo=2 -C debug-assertions=on -C overflow-checks=on" ;;
  test)    OPT="-C opt-level=2 -C debug-assertions=on -C overflow-checks=on" ;;
  *) echo "usage: $0 [release|debug|test]"; exit 2 ;;
esac
# the std-only core (frame splitting, inflate, AES-128-CFB8 reference, SHA-1, server hash)
rustc $FLAGS_COMMON $OPT --crate-type rlib --crate-name dbcraft_gateway_core core/src/lib.rs -o "$CORE"
LIBS=""   # nothing to pass: the #[link] attributes in src/ffi/ name libpq, libcrypto and libcurl.so.4
if [ "$mode" = test ]; then
  rustc $FLAGS_COMMON $OPT --test --crate-name dbcraft_gateway_core core/src/lib.rs -o "$T/core-tests"
  rustc $FLAGS_COMMON $OPT --test src/main.rs --extern dbcraft_gateway_core="$CORE" -L "$T" $LIBS -o "$T/gateway-tests"
  "$T/core-tests" -q
  # the core's integration tests (adacraft corpus, real-zlib inflate vectors, randomised stress): each is its own test crate
  for t in core/tests/*.rs; do
    n="$(basename "$t" .rs)"
    rustc $FLAGS_COMMON $OPT --test "$t" --extern dbcraft_gateway_core="$CORE" -L "$T" -o "$T/core-it-$n"
    "$T/core-it-$n" -q
  done
  "$T/gateway-tests" -q
else
  OUT="$T/dbcraft-gateway"; [ "$mode" = debug ] && OUT="$T/dbcraft-gateway-debug"
  rustc $FLAGS_COMMON $OPT src/main.rs --extern dbcraft_gateway_core="$CORE" -L "$T" $LIBS -o "$OUT"
  echo "built $OUT"
fi
