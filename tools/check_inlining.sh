#!/usr/bin/env bash
# Structural guard: on a CLEAN migration, every function in sql/INLINE_HOT.txt still has the inlining behaviour that was measured to matter.
# usage: tools/check_inlining.sh      uses the dev cluster (DBCRAFT_PGPORT, default 54329); creates and drops database dbcraft_inl_check
# The inlining probe (tools/audit_inlining.sql) plans a representative call over a real table and looks for the function's name in EXPLAIN VERBOSE.
set -euo pipefail
cd "$(dirname "$0")/.."
export PGHOST=/tmp PGPORT=${DBCRAFT_PGPORT:-54329} PGUSER=postgres
psql -X -q -d postgres -c "drop database if exists dbcraft_inl_check" -c "create database dbcraft_inl_check" 2>/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists dbcraft_inl_check" 2>/dev/null' EXIT
PGDATABASE=dbcraft_inl_check tools/migrate.sh --fresh >/dev/null 2>&1
PGDATABASE=dbcraft_inl_check python3 tools/audit_inlining.py --check
