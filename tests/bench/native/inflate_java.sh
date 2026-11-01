#!/usr/bin/env bash
# Java's java.util.zip.Inflater (the client's inflater) over every stream tests/sql/441_deflate_native.sql judged with Python's zlib.
# Run the SQL test first (it writes /tmp/dbcraft_native_zin.tsv), then:   tests/bench/native/inflate_java.sh
# Needs a JDK/JRE 11+ (`java` on the PATH, or JAVA=/path/to/java).  Only compiles and runs the one small class in this directory.
set -euo pipefail
cd "$(dirname "$0")/../../.."
IN=${1:-/tmp/dbcraft_native_zin.tsv}
[ -s "$IN" ] || { echo "no $IN: run tests/sql/run.sh native first" >&2; exit 2; }
exec "${JAVA:-java}" tests/bench/native/InflateCheck.java < "$IN"
