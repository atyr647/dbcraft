#!/usr/bin/env bash
# Reload the schema and run pg/test.sql (prints PASS lines, fails loudly).
set -euo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = "--no-load" ] || ./load.sh
psql -h 127.0.0.1 -p 54340 -U postgres dlcraft -v ON_ERROR_STOP=1 -q -f test.sql
