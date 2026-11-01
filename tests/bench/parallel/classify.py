#!/usr/bin/env python3
"""Classify the statements of one tick (output of dump_stmts.sql) by what the PostgreSQL 16 planner/executor allows.

usage: classify.py STMTS.tsv [TICK_MS]

Rules used (PG16):
  * a statement that modifies data (INSERT/UPDATE/DELETE, also inside a CTE) is never planned with a Gather: DML = no parallelism.
  * a pure SELECT is parallel-eligible only if every function it calls is PARALLEL SAFE (user functions default to UNSAFE), it touches no temp table and
    PL/pgSQL runs it without a row limit (PERFORM / plain query; `SELECT ... INTO`, `x := (select ...)`, FOR loops run with a limit or a cursor: no workers).
  * "wrapper" rows are the calls of whole functions (they contain the nested statements listed separately): excluded from totals to avoid double counting.
"""
import re, sys
rows = [l.rstrip('\n').split('#!#') for l in open(sys.argv[1]) if l.strip()]
tick = float(sys.argv[2]) if len(sys.argv) > 2 else None
dml = re.compile(r'\b(insert\s+into|update\s+[a-z_.]+\s+(set|as)|delete\s+from)\b', re.I)
wrapper = re.compile(r'^(select \* from mc\.(apply_player_moves|refresh_visibility)\(|select (net|mc)\.[a-z_]+\(|select \* from net\.drain|call )', re.I)
kinds = {'dml': 0.0, 'select': 0.0, 'wrapper': 0.0}
sel = []
for r in rows:
    ms, q = float(r[0]), r[5]
    k = 'wrapper' if wrapper.match(q) else ('dml' if dml.search(q) else 'select')
    kinds[k] += ms
    if k == 'select':
        sel.append((ms, r[3], q))
leaf = kinds['dml'] + kinds['select']
print('per tick (ms): data-modifying leaf statements %.2f, read-only leaf statements %.2f, leaf total %.2f (wrappers %.2f excluded)' % (kinds['dml'], kinds['select'], leaf, kinds['wrapper']))
if leaf:
    print('read-only share of the statement time: %.1f%%' % (100 * kinds['select'] / leaf))
if tick:
    print('read-only share of the tick wall time: %.1f%% (tick %.1f ms)' % (100 * kinds['select'] / tick, tick))
print('\nread-only statements, most expensive first (ms per tick, calls per tick, text):')
for ms, calls, q in sorted(sel, reverse=True)[:25]:
    print('%8.3f  %5s  %s' % (ms, calls, q[:150]))
