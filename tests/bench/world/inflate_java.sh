#!/usr/bin/env bash
# Second inflater for the SQL DEFLATE encoder: Java's java.util.zip.Inflater (the one the client uses) over the streams tests/sql/280_world_deflate.sql judged with
# Python's zlib.  Run the SQL test first (it writes /tmp/dbcraft_zin.tsv), then:
#   tests/bench/world/inflate_java.sh
# Needs a JDK/JRE 11+ (`java` on the PATH, or JAVA=/path/to/java).  Only compiles and runs the one small class in this directory.
set -euo pipefail
cd "$(dirname "$0")/../../.."
IN=${1:-/tmp/dbcraft_zin.tsv}
[ -s "$IN" ] || { echo "no $IN: run tests/sql/run.sh world_deflate first" >&2; exit 2; }
exec "${JAVA:-java}" tests/bench/world/InflateCheck.java < "$IN"
