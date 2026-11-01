#!/usr/bin/env bash
# AES-128-CFB8 of the gateway core against the real `openssl` binary, for random keys and random data sizes, with the stream cut into random-sized
# chunks by the tool (so the state carried between chunks is exercised).  Both directions.
# usage: tests/gateway/cfb8_openssl.sh [rounds]     (builds the core with rustc into a temp dir; needs openssl)
set -euo pipefail
cd "$(dirname "$0")/../.."
ROUNDS=${1:-40}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
rustc --edition 2021 --crate-type rlib --crate-name dbcraft_gateway_core -O gateway/core/src/lib.rs --out-dir "$T" 2>&1
rustc --edition 2021 -O gateway/core/examples/cfb8_tool.rs --extern dbcraft_gateway_core="$T/libdbcraft_gateway_core.rlib" -o "$T/cfb8_tool" 2>&1
fail=0
for i in $(seq 1 "$ROUNDS"); do
  key=$(openssl rand -hex 16)
  size=$(( (RANDOM * 7 + RANDOM) % 200000 + 1 ))
  head -c "$size" /dev/urandom > "$T/plain"
  openssl enc -aes-128-cfb8 -K "$key" -iv "$key" < "$T/plain" > "$T/ref_ct"
  "$T/cfb8_tool" enc "$key" "$RANDOM$RANDOM" < "$T/plain" > "$T/our_ct"
  if ! cmp -s "$T/ref_ct" "$T/our_ct"; then echo "FAIL encrypt round $i (size $size key $key)"; fail=1; fi
  "$T/cfb8_tool" dec "$key" "$RANDOM$RANDOM" < "$T/ref_ct" > "$T/our_pt"
  if ! cmp -s "$T/plain" "$T/our_pt"; then echo "FAIL decrypt round $i (size $size key $key)"; fail=1; fi
done
if [ "$fail" = 0 ]; then echo "ok: $ROUNDS rounds, encrypt and decrypt identical to openssl"; fi
exit $fail
