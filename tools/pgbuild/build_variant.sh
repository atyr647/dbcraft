#!/usr/bin/env bash
# Build one PostgreSQL 16.15 variant from the distro's patched source (see fetch_src.sh) into /tmp/pg-runtime-<variant>.
#   usage: tools/pgbuild/build_variant.sh B|C|D1|D2
#   B   plain -O2 (control: the distro adds hardening flags and its own configure options)
#   C   -O3 -march=native -fno-plt, LTO
#   D1  C + -fprofile-generate (instrumented; run the training workload against it: tools/pgbuild/train.sh)
#   D2  C + -fprofile-use (the PGO build; needs the profile data written by D1)
# Everything runs under `nice -n 15`.  Out-of-tree builds in /tmp/pgbuild/<variant>.  D1 and D2 share one build directory name
# (/tmp/pgbuild/D) because gcc names profile files after the object path.
set -euo pipefail
V=${1:?variant B|C|D1|D2}
SRC=$(ls -d /tmp/pgsrc-distro/postgresql-16-16.*/ | head -1)
PGO=/tmp/pgbuild/pgo-data
case "$V" in
  B)  CF="-O2";                                                                    LF="";            BD=/tmp/pgbuild/B ;;
  C)  CF="-O3 -march=native -fno-plt -flto=auto";                                  LF="-flto=auto";  BD=/tmp/pgbuild/C ;;
  D1) CF="-O3 -march=native -fno-plt -flto=auto -fprofile-generate=$PGO";          LF="-flto=auto -fprofile-generate=$PGO"; BD=/tmp/pgbuild/D ;;
  D2) CF="-O3 -march=native -fno-plt -flto=auto -fprofile-use=$PGO -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch"; LF="-flto=auto"; BD=/tmp/pgbuild/D ;;   # the profile was trained without lz4/zstd: the few functions that differ simply get no profile
  *)  echo "unknown variant $V"; exit 2 ;;
esac
PREFIX=/tmp/pg-runtime-$V
mkdir -p "$BD" "$PGO"
chmod 1777 "$PGO"          # the instrumented server runs as the postgres user and writes its .gcda files here
cd "$BD"
if [ -z "${RESUME:-}" ]; then            # RESUME=1: keep the build directory and continue the make (after the libpq check below)
  rm -rf "$BD" "$PREFIX"; mkdir -p "$BD"; cd "$BD"
  # D2 also gets lz4 and zstd (the distro binary has them; the dbcraft suite uses lz4 for the opt-in section compression, sql/291).
  # B, C and D1 were built before that was found and have neither: the benchmarks never use them (default_toast_compression is pglz).
  EXTRA=""; if [ "$V" = D2 ]; then EXTRA="--with-lz4 --with-zstd"; fi
  nice -n 15 "$SRC/configure" --prefix="$PREFIX" --without-icu --without-llvm --with-openssl --with-zlib $EXTRA \
       CFLAGS="$CF" LDFLAGS="$LF" > configure.log 2>&1
fi
if ! nice -n 15 make -j4 > make.log 2>&1; then
  # The instrumented build (-fprofile-generate) links gcov's exit handler into libpq, which PostgreSQL's own libpq-refs check forbids
  # ("libpq must not be calling any function which invokes exit").  libpq itself has been built by then: mark the check done for D1 only.
  if [ "$V" = D1 ] && grep -q "libpq must not be calling" make.log; then
    touch src/interfaces/libpq/libpq-refs-stamp
    nice -n 15 make -j4 > make.log 2>&1
  else
    exit 1
  fi
fi
nice -n 15 make install > install.log 2>&1
chmod -R a+rX "$PREFIX"
"$PREFIX/bin/postgres" --version
echo "configure line: $SRC/configure --prefix=$PREFIX --without-icu --without-llvm --with-openssl --with-zlib CFLAGS='$CF' LDFLAGS='$LF'"
