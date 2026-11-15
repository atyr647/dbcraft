#!/usr/bin/env bash
# Run Clojure with the dlcraft deps and the JVM flags Datalevin needs on JDK 21.  Usage: tools/clj.sh -M -m bench.main ...   (or -e '(...)')
# The Clojure CLI lives in $DLCRAFT_HOME/tools/clojure (see README "Setup").
ROOT=${DLCRAFT_HOME:-/srv/dlcraft}
export PATH=$ROOT/tools/clojure/bin:$PATH
cd "$(dirname "$0")/.."
exec clojure -A:run "$@"
